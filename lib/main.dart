import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';

void main() => runApp(const SoninkeEchoApp());

// ---------- Couleurs ----------
const violet = Color(0xFF6A3DE8);
const orange = Color(0xFFFF7A00);
const turquoise = Color(0xFF00A79D);
const fond = Color(0xFFF5F2FF);

const degrade = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [violet, Color(0xFFAB47BC), Color(0xFFFF7043)],
);

String cap(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

// ---------- Données ----------
// Lit une valeur en essayant plusieurs noms de colonnes (format court ou format Google Sheet)
String pick(Map<String, dynamic> j, List<String> keys) {
  for (final k in keys) {
    final v = j[k];
    if (v != null && v.toString().trim().isNotEmpty && v.toString().trim() != '-') {
      return v.toString().trim();
    }
  }
  return '';
}

class Entry {
  final String fr, so, audioSo, audioFr, theme, phon;
  Entry(Map<String, dynamic> j)
      : fr = pick(j, ['fr', 'Mots français', 'Mots francais']),
        so = pick(j, ['so', 'Mots soninké', 'Mots soninke']),
        audioSo = pick(j, ['audioSo', 'Audio_Soninké', 'Audio_Soninke']),
        audioFr = pick(j, ['audioFr', 'Audio_Français', 'Audio_Francais']),
        theme = pick(j, ['theme', 'Thème', 'Theme']).toLowerCase(),
        phon = pick(j, ['phon', 'phonetique micro', 'phonétique micro']); // recherche uniquement, jamais affiché
  String get id => '$fr|$so';
}

class Phrase {
  final String fr, so;
  Phrase(Map<String, dynamic> j)
      : fr = pick(j, ['fr', 'Phrases français', 'Phrases francais']),
        so = pick(j, ['so', 'Phrases soninké', 'Phrases soninke']);
  String get id => 'p:$fr|$so';
}

String norm(String s) {
  const from = 'àâäéèêëîïôöùûüçñŋ';
  const to = 'aaaeeeeiioouuucnn';
  var r = s.toLowerCase();
  for (var i = 0; i < from.length; i++) {
    r = r.replaceAll(from[i], to[i]);
  }
  return r.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
}

String flat(String s) => norm(s).replaceAll(' ', '');

// Clé "sonore" : rapproche des écritures qui se prononcent presque pareil
// (ex. « saumon » ~ « somo », « toulou » ~ « tolu »).
String phoKey(String s) {
  var r = flat(s);
  const reps = [
    ['eau', 'o'], ['au', 'o'], ['ou', 'u'], ['ph', 'f'], ['qu', 'k'], ['ch', 's'],
    ['gu', 'g'], ['ai', 'e'], ['ei', 'e'], ['kh', 'k'], ['gn', 'n'], ['oi', 'ua'],
  ];
  for (final p in reps) {
    r = r.replaceAll(p[0], p[1]);
  }
  r = r.replaceAll(RegExp(r'c(?=[ei])'), 's');
  r = r
      .replaceAll('c', 'k')
      .replaceAll('q', 'k')
      .replaceAll('x', 'k')
      .replaceAll('y', 'i')
      .replaceAll('w', 'u')
      .replaceAll('h', '')
      .replaceAll('o', 'u');
  return r.replaceAllMapped(RegExp(r'(.)\1+'), (m) => m.group(1)!);
}

int lev(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  var prev = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final cur = List<int>.filled(b.length + 1, 0);
    cur[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final c = a[i - 1] == b[j - 1] ? 0 : 1;
      var m = prev[j] + 1;
      if (cur[j - 1] + 1 < m) m = cur[j - 1] + 1;
      if (prev[j - 1] + c < m) m = prev[j - 1] + c;
      cur[j] = m;
    }
    prev = cur;
  }
  return prev[b.length];
}

int? pairScore(String a, String b) {
  if (a.isEmpty || b.isEmpty) return null;
  if (a == b) return 0;
  if (a.length >= 3 && b.length >= 3 && (a.contains(b) || b.contains(a))) return 1;
  final tol = b.length <= 4 ? 1 : 2;
  final d = lev(a, b);
  return d <= tol ? 1 + d : null;
}

int infoCount(Entry e) =>
    (e.audioSo.isNotEmpty ? 1 : 0) +
    (e.audioFr.isNotEmpty ? 1 : 0) +
    (e.theme.isNotEmpty ? 1 : 0) +
    (e.phon.isNotEmpty ? 1 : 0);

class AppState extends ChangeNotifier {
  List<Entry> words = [];
  List<Phrase> phrases = [];
  Map<String, Entry> byId = {};
  Set<String> favs = {};
  SharedPreferences? _p;
  final player = AudioPlayer();
  bool loaded = false;
  String? error;

  // Apprentissage vocal : ce que le micro a entendu -> le bon mot
  final Map<String, Set<String>> learned = {};
  final List<String> learnedRaw = [];
  List<String> lastHeard = [];

  Future<void> load() async {
    // --- mots ---
    try {
      final raw = await rootBundle.loadString('assets/data/data.json');
      final j = jsonDecode(raw);
      final List wl = j is List ? j : (j['words'] ?? j['mots'] ?? []);
      final m = <String, Entry>{};
      for (final x in wl) {
        final e = Entry(Map<String, dynamic>.from(x));
        if (e.fr.isEmpty || e.so.isEmpty) continue;
        final k = '${norm(e.fr)}|${norm(e.so)}';
        final o = m[k];
        if (o == null || infoCount(e) > infoCount(o)) m[k] = e;
      }
      words = m.values.toList();
      byId = {for (final e in words) e.id: e};
      if (words.isEmpty) {
        error = "Le fichier data.json a été lu, mais aucun mot n'a été trouvé "
            "(vérifiez les noms de colonnes).";
      }
    } catch (e) {
      error = 'Impossible de lire assets/data/data.json : $e';
    }
    // --- phrases (dans data.json et/ou dans phrases.json) ---
    final List pl = [];
    try {
      final j = jsonDecode(await rootBundle.loadString('assets/data/data.json'));
      if (j is Map && j['phrases'] is List) pl.addAll(j['phrases'] as List);
    } catch (_) {}
    try {
      final j2 = jsonDecode(await rootBundle.loadString('assets/data/phrases.json'));
      final List l2 = j2 is List ? j2 : (j2['phrases'] ?? []);
      pl.addAll(l2);
    } catch (_) {}
    final pm = <String, Phrase>{};
    for (final x in pl) {
      final p = Phrase(Map<String, dynamic>.from(x));
      if (p.fr.isEmpty || p.so.isEmpty) continue;
      pm['${norm(p.fr)}|${norm(p.so)}'] = p;
    }
    phrases = pm.values.toList();
    // --- favoris et apprentissage ---
    try {
      _p = await SharedPreferences.getInstance();
      favs = (_p!.getStringList('favs') ?? []).toSet();
      for (final rec in _p!.getStringList('learned') ?? <String>[]) {
        final parts = rec.split('\t');
        if (parts.length < 2) continue;
        learnedRaw.add(rec);
        learned.putIfAbsent(phoKey(parts[0]), () => <String>{}).add(parts[1]);
      }
    } catch (_) {}
    loaded = true;
    notifyListeners();
  }

  void toggleFav(String id) {
    favs.contains(id) ? favs.remove(id) : favs.add(id);
    _p?.setStringList('favs', favs.toList());
    notifyListeners();
  }

  void learn(Entry e, List<String> heard) {
    for (final h in heard.take(3)) {
      final k = phoKey(h);
      if (k.isEmpty) continue;
      final rec = '${h.trim()}\t${e.id}';
      if (learnedRaw.contains(rec)) continue;
      learnedRaw.add(rec);
      learned.putIfAbsent(k, () => <String>{}).add(e.id);
    }
    _p?.setStringList('learned', learnedRaw);
    notifyListeners();
  }

  // Texte à coller dans le Sheet : mot soninké, mot français, ce que le micro a entendu
  String exportLearned() {
    final byEntry = <String, Set<String>>{};
    for (final rec in learnedRaw) {
      final p = rec.split('\t');
      if (p.length < 2) continue;
      byEntry.putIfAbsent(p[1], () => <String>{}).add(p[0].toLowerCase());
    }
    final b = StringBuffer();
    byEntry.forEach((id, hs) {
      final e = byId[id];
      if (e != null) b.writeln('${e.so}\t${e.fr}\t${hs.join(', ')}');
    });
    return b.toString();
  }

  Future<void> play(String url) async {
    if (url.isEmpty) return;
    try {
      await player.setUrl(Uri.encodeFull(url));
      await player.play();
    } catch (_) {}
  }

  // Score de ressemblance (le plus petit = le mieux), à l'écrit et au son.
  int? fuzzyScore(Entry w, String q) {
    final n = flat(q);
    if (n.length < 2) return null;
    final nk = phoKey(q);
    final cands = <String>[w.fr, w.so, ...w.phon.split(',')];
    int? best;
    for (final x in cands) {
      final s1 = pairScore(flat(x), n);
      final s2 = pairScore(phoKey(x), nk);
      for (final s in [s1, s2]) {
        if (s != null && (best == null || s < best)) best = s;
      }
    }
    return best;
  }

  // Recherche : ce qu'on a appris d'abord, puis les correspondances directes,
  // puis les mots qui "sonnent" pareil (utilise aussi les autres propositions du micro).
  List<Entry> search(String q, {List<String> alts = const [], Iterable<Entry>? pool}) {
    final src = (pool ?? words).toList();
    final srcSet = src.toSet();
    final queries = <String>[];
    for (final x in [q, ...alts]) {
      if (norm(x).isNotEmpty && !queries.contains(x)) queries.add(x);
    }
    if (queries.isEmpty) return [];
    final out = <Entry>[];
    void add(Entry e) {
      if (!out.contains(e)) out.add(e);
    }

    for (final x in queries) {
      for (final id in learned[phoKey(x)] ?? <String>{}) {
        final e = byId[id];
        if (e != null && srcSet.contains(e)) add(e);
      }
    }
    final n = norm(q);
    final direct = n.isEmpty
        ? <Entry>[]
        : src
            .where((w) =>
                norm(w.fr).contains(n) || norm(w.so).contains(n) || norm(w.phon).contains(n))
            .toList();
    int score(Entry w) {
      if (norm(w.fr) == n || norm(w.so) == n) return 0;
      if (norm(w.fr).startsWith(n) || norm(w.so).startsWith(n)) return 1;
      return 2;
    }

    direct.sort((a, b) => score(a).compareTo(score(b)));
    direct.forEach(add);
    if (direct.isEmpty || alts.isNotEmpty) {
      final scored = <Entry, int>{};
      for (final x in queries) {
        for (final w in src) {
          final s = fuzzyScore(w, x);
          if (s != null && (scored[w] == null || s < scored[w]!)) scored[w] = s;
        }
      }
      final list = scored.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
      for (final e in list.take(30)) {
        add(e.key);
      }
    }
    return out;
  }
}

final state = AppState();
final themeFilter = ValueNotifier<String?>(null);

// ---------- Application ----------
class SoninkeEchoApp extends StatelessWidget {
  const SoninkeEchoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: "Sonink'Écho",
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: violet),
          scaffoldBackgroundColor: fond,
          useMaterial3: true,
        ),
        home: const Home(),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int tab = 0;
  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    state.addListener(_rebuild);
    state.load();
  }

  @override
  void dispose() {
    state.removeListener(_rebuild);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const SearchPage(),
      const DictPage(),
      const PhrasesPage(),
      const FavsPage(),
    ];
    return Scaffold(
      body: !state.loaded
          ? const Center(child: CircularProgressIndicator(color: violet))
          : (state.words.isEmpty
              ? Center(
                  child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(state.error ?? 'Aucun mot à afficher.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 16, color: Colors.red))))
              : pages[tab]),
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(gradient: degrade),
        child: NavigationBarTheme(
          data: NavigationBarThemeData(
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            indicatorColor: Colors.white.withValues(alpha: 0.28),
            labelTextStyle: const WidgetStatePropertyAll(
                TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          ),
          child: NavigationBar(
            selectedIndex: tab,
            onDestinationSelected: (i) => setState(() => tab = i),
            destinations: const [
              NavigationDestination(
                  icon: Icon(Icons.translate, color: Colors.white70),
                  selectedIcon: Icon(Icons.translate, color: Colors.white),
                  label: 'Traduire'),
              NavigationDestination(
                  icon: Icon(Icons.menu_book_outlined, color: Colors.white70),
                  selectedIcon: Icon(Icons.menu_book, color: Colors.white),
                  label: 'Dictionnaire'),
              NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline, color: Colors.white70),
                  selectedIcon: Icon(Icons.chat_bubble, color: Colors.white),
                  label: 'Phrases'),
              NavigationDestination(
                  icon: Icon(Icons.star_border, color: Colors.white70),
                  selectedIcon: Icon(Icons.star, color: Colors.white),
                  label: 'Favoris'),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------- Composants ----------
class GradientHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? child;
  const GradientHeader({super.key, required this.title, this.subtitle, this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(20, MediaQuery.of(context).padding.top + 16, 20, 20),
      decoration: const BoxDecoration(
        gradient: degrade,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(32)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.graphic_eq, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
          ]),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ],
          if (child != null) ...[const SizedBox(height: 14), child!],
        ],
      ),
    );
  }
}

// Barre de recherche avec micro (recherche vocale)
class SearchField extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  final ValueChanged<List<String>>? onVoice;
  const SearchField({super.key, required this.hint, required this.onChanged, this.onVoice});
  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final ctrl = TextEditingController();
  final stt = SpeechToText();
  bool ready = false;
  bool listening = false;

  @override
  void initState() {
    super.initState();
    ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    stt.cancel();
    ctrl.dispose();
    super.dispose();
  }

  Future<void> toggleMic() async {
    if (listening) {
      await stt.stop();
      if (mounted) setState(() => listening = false);
      return;
    }
    if (!ready) {
      try {
        ready = await stt.initialize(
          onStatus: (s) {
            if ((s == 'done' || s == 'notListening') && mounted) {
              setState(() => listening = false);
            }
          },
          onError: (e) {
            if (mounted) setState(() => listening = false);
          },
        );
      } catch (_) {
        ready = false;
      }
    }
    if (!ready) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Micro indisponible : autorisez le micro et la reconnaissance vocale dans les réglages du téléphone.')));
      }
      return;
    }
    setState(() => listening = true);
    await stt.listen(
      localeId: 'fr_FR',
      listenFor: const Duration(seconds: 8),
      pauseFor: const Duration(seconds: 3),
      onResult: (r) {
        final alts = <String>[];
        void add(String x) {
          final t = x.trim();
          if (t.isNotEmpty && !alts.contains(t)) alts.add(t);
        }

        add(r.recognizedWords);
        for (final a in r.alternates) {
          add(a.recognizedWords);
        }
        if (alts.isEmpty) return;
        ctrl.text = alts.first;
        ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
        if (widget.onVoice != null) {
          widget.onVoice!(alts);
        } else {
          widget.onChanged(alts.first);
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.12), blurRadius: 10, offset: const Offset(0, 4))
        ],
      ),
      child: TextField(
        controller: ctrl,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, color: violet),
          hintText: listening ? 'Je vous écoute… parlez maintenant 🎤' : widget.hint,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
          suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
            if (ctrl.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close, color: Colors.grey),
                onPressed: () {
                  ctrl.clear();
                  widget.onChanged('');
                },
              ),
            IconButton(
              tooltip: 'Recherche vocale',
              icon: Icon(listening ? Icons.mic : Icons.mic_none,
                  color: listening ? Colors.red : violet, size: 26),
              onPressed: toggleMic,
            ),
          ]),
        ),
      ),
    );
  }
}

class AudioBtn extends StatelessWidget {
  final String label, url;
  final Color color;
  const AudioBtn({super.key, required this.label, required this.url, required this.color});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => state.play(url),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.volume_up_rounded, color: color, size: 20),
            const SizedBox(width: 3),
            Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 12)),
          ]),
        ),
      ),
    );
  }
}

class FavBtn extends StatelessWidget {
  final String id;
  const FavBtn(this.id, {super.key});
  @override
  Widget build(BuildContext context) {
    final fav = state.favs.contains(id);
    return IconButton(
      icon: Icon(fav ? Icons.star_rounded : Icons.star_border_rounded,
          color: Colors.amber, size: 28),
      onPressed: () => state.toggleFav(id),
    );
  }
}

class CardShell extends StatelessWidget {
  final Color color;
  final Widget child;
  const CardShell({super.key, required this.color, required this.child});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.16), blurRadius: 12, offset: const Offset(0, 4))
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(width: 7, color: color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
                child: child,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

class WordTile extends StatelessWidget {
  final Entry e;
  const WordTile(this.e, {super.key});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (state.lastHeard.isEmpty) return;
        final h = List<String>.from(state.lastHeard);
        state.lastHeard = [];
        state.learn(e, h);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Retenu : « ${h.first} » = ${e.so}')));
      },
      child: CardShell(
      color: violet,
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.so,
                style: const TextStyle(
                    fontSize: 20, fontWeight: FontWeight.w800, color: violet)),
            const SizedBox(height: 2),
            Text(e.fr, style: const TextStyle(fontSize: 15, color: Colors.black87)),
            if (e.theme.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: const Color(0xFFEFEAFB), borderRadius: BorderRadius.circular(10)),
                child: Text(cap(e.theme),
                    style: const TextStyle(
                        color: Color(0xFF6B5E8F), fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ]),
        ),
        Column(mainAxisSize: MainAxisSize.min, children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (e.audioFr.isNotEmpty)
              AudioBtn(label: 'FR', url: e.audioFr, color: const Color(0xFF2979FF)),
            if (e.audioSo.isNotEmpty)
              AudioBtn(label: 'SO', url: e.audioSo, color: const Color(0xFF00A86B)),
          ]),
          FavBtn(e.id),
        ]),
      ]),
    ));
  }
}

class PhraseTile extends StatelessWidget {
  final Phrase p;
  const PhraseTile(this.p, {super.key});
  @override
  Widget build(BuildContext context) {
    return CardShell(
      color: turquoise,
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.so,
                style: const TextStyle(
                    fontSize: 17, fontWeight: FontWeight.w800, color: turquoise)),
            const SizedBox(height: 4),
            Text(p.fr, style: const TextStyle(fontSize: 15, color: Colors.black87)),
          ]),
        ),
        FavBtn(p.id),
      ]),
    );
  }
}

// ---------- Page Traduire ----------
class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String q = '';
  List<String> alts = [];

  @override
  Widget build(BuildContext context) {
    final res = state.search(q, alts: alts);
    final wod = state.words.isEmpty
        ? null
        : state.words[DateTime.now().day % state.words.length];

    return Column(children: [
      GradientHeader(
        title: "Sonink'Écho",
        subtitle: 'Votre traducteur français ⇄ soninké',
        child: SearchField(
          hint: 'Écrire ou dire un mot…',
          onChanged: (v) {
            state.lastHeard = [];
            setState(() {
              q = v;
              alts = [];
            });
          },
          onVoice: (a) {
            state.lastHeard = a;
            setState(() {
              q = a.first;
              alts = a;
            });
          },
        ),
      ),
      Expanded(
        child: q.trim().isNotEmpty
            ? (res.isEmpty
                ? const Center(child: Text('Aucun résultat 🤔'))
                : ListView(
                    padding: const EdgeInsets.only(top: 10),
                    children: [for (final e in res) WordTile(e)]))
            : ListView(padding: const EdgeInsets.only(top: 14), children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(children: [
                    _Pill(Icons.abc, '${state.words.length} mots', violet),
                    const SizedBox(width: 8),
                    _Pill(Icons.chat_bubble_outline, '${state.phrases.length} phrases', turquoise),
                  ]),
                ),
                const SizedBox(height: 16),
                if (wod != null) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('✨ Mot du jour',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(height: 4),
                  WordTile(wod),
                ],
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 20, 16, 0),
                  child: Text(
                      '🎤 Appuyez sur le micro et dites un mot en français ou en soninké. '
                      'Si le bon mot apparaît dans la liste, touchez-le : l\'appli apprendra et le reconnaîtra mieux la prochaine fois.',
                      style: TextStyle(color: Colors.black54)),
                ),
                if (state.learnedRaw.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.copy, size: 18),
                        label: Text('Copier mes essais vocaux (${state.learnedRaw.length})'),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: state.exportLearned()));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                content: Text('Copié ! Collez-le dans votre Google Sheet.')));
                          }
                        },
                      ),
                    ),
                  ),
              ]),
      ),
    ]);
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _Pill(this.icon, this.text, this.color);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Text(text,
            style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12)),
      ]),
    );
  }
}

// ---------- Page Dictionnaire ----------
class DictPage extends StatefulWidget {
  const DictPage({super.key});
  @override
  State<DictPage> createState() => _DictPageState();
}

class _DictPageState extends State<DictPage> {
  bool frToSo = true;
  String q = '';
  List<String> alts = [];

  @override
  Widget build(BuildContext context) {
    final theme = themeFilter.value;
    final themes = state.words.map((w) => w.theme).where((t) => t.isNotEmpty).toSet().toList()..sort();
    final pool = state.words.where((w) => theme == null || w.theme == theme).toList();
    List<Entry> list;
    if (q.trim().isEmpty) {
      list = pool;
      list.sort((a, b) => norm(frToSo ? a.fr : a.so).compareTo(norm(frToSo ? b.fr : b.so)));
    } else {
      list = state.search(q, alts: alts, pool: pool);
    }

    return Column(children: [
      GradientHeader(
        title: 'Dictionnaire',
        subtitle: frToSo ? 'Français → Soninké' : 'Soninké → Français',
        child: Column(children: [
          SearchField(
            hint: 'Écrire ou dire un mot…',
            onChanged: (v) {
              state.lastHeard = [];
              setState(() {
                q = v;
                alts = [];
              });
            },
            onVoice: (a) {
              state.lastHeard = a;
              setState(() {
                q = a.first;
                alts = a;
              });
            },
          ),
          const SizedBox(height: 10),
          Row(children: [
            _Toggle('Français → Soninké', frToSo, () => setState(() => frToSo = true)),
            const SizedBox(width: 8),
            _Toggle('Soninké → Français', !frToSo, () => setState(() => frToSo = false)),
          ]),
        ]),
      ),
      SizedBox(
        height: 56,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          children: [
            _Chip('Tous', theme == null, () => setState(() => themeFilter.value = null)),
            for (final t in themes)
              _Chip(cap(t), theme == t, () => setState(() => themeFilter.value = t)),
          ],
        ),
      ),
      Expanded(
        child: list.isEmpty
            ? const Center(child: Text('Aucun mot trouvé'))
            : ListView.builder(
                itemCount: list.length, itemBuilder: (_, i) => WordTile(list[i])),
      ),
    ]);
  }
}

class _Toggle extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback tap;
  const _Toggle(this.label, this.on, this.tap);
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? Colors.white : Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: on ? violet : Colors.white)),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool on;
  final VoidCallback tap;
  const _Chip(this.label, this.on, this.tap);
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: tap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: on ? violet : Colors.white,
            border: Border.all(color: on ? violet : const Color(0xFFD9D2EE)),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(label,
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: on ? Colors.white : const Color(0xFF5A4E80))),
        ),
      ),
    );
  }
}

// ---------- Page Phrases ----------
class PhrasesPage extends StatefulWidget {
  const PhrasesPage({super.key});
  @override
  State<PhrasesPage> createState() => _PhrasesPageState();
}

class _PhrasesPageState extends State<PhrasesPage> {
  String q = '';
  List<String> alts = [];
  @override
  Widget build(BuildContext context) {
    final qs = <String>[q, ...alts].map(norm).where((x) => x.isNotEmpty).toList();
    final list = state.phrases
        .where((p) =>
            qs.isEmpty || qs.any((n) => norm(p.fr).contains(n) || norm(p.so).contains(n)))
        .toList();
    return Column(children: [
      GradientHeader(
        title: 'Phrases utiles',
        subtitle: '${state.phrases.length} phrases du quotidien',
        child: SearchField(
          hint: 'Écrire ou dire une phrase…',
          onChanged: (v) => setState(() {
            q = v;
            alts = [];
          }),
          onVoice: (a) => setState(() {
            q = a.first;
            alts = a;
          }),
        ),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.only(top: 10, bottom: 10),
          itemCount: list.length,
          itemBuilder: (_, i) => PhraseTile(list[i]),
        ),
      ),
    ]);
  }
}

// ---------- Page Favoris ----------
class FavsPage extends StatelessWidget {
  const FavsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final ws = state.words.where((w) => state.favs.contains(w.id)).toList();
    final ps = state.phrases.where((p) => state.favs.contains(p.id)).toList();
    return Column(children: [
      const GradientHeader(title: 'Mes favoris', subtitle: 'Vos mots et phrases préférés ⭐'),
      Expanded(
        child: (ws.isEmpty && ps.isEmpty)
            ? const Center(
                child: Padding(
                padding: EdgeInsets.all(30),
                child: Text(
                    "Aucun favori pour l'instant.\nAppuyez sur ⭐ à côté d'un mot pour l'ajouter.",
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16)),
              ))
            : ListView(padding: const EdgeInsets.only(top: 10), children: [
                for (final w in ws) WordTile(w),
                for (final p in ps) PhraseTile(p),
              ]),
      ),
    ]);
  }
}
