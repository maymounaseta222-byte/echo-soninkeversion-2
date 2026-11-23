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

class AppState extends ChangeNotifier {
  List<Entry> words = [];
  List<Phrase> phrases = [];
  Set<String> favs = {};
  SharedPreferences? _p;
  final player = AudioPlayer();
  bool loaded = false;
  String? error;

  Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/data/data.json');
      final j = jsonDecode(raw);
      final List wl = j is List ? j : (j['words'] ?? j['mots'] ?? []);
      final List pl = j is List ? [] : (j['phrases'] ?? []);
      words = wl
          .map((e) => Entry(Map<String, dynamic>.from(e)))
          .where((e) => e.fr.isNotEmpty && e.so.isNotEmpty)
          .toList();
      phrases = pl
          .map((e) => Phrase(Map<String, dynamic>.from(e)))
          .where((e) => e.fr.isNotEmpty && e.so.isNotEmpty)
          .toList();
      if (words.isEmpty) {
        error = "Le fichier data.json a été lu, mais aucun mot n'a été trouvé "
            "(vérifiez les noms de colonnes).";
      }
    } catch (e) {
      error = 'Impossible de lire assets/data/data.json : $e';
    }
    try {
      _p = await SharedPreferences.getInstance();
      favs = (_p!.getStringList('favs') ?? []).toSet();
    } catch (_) {}
    loaded = true;
    notifyListeners();
  }

  void toggleFav(String id) {
    favs.contains(id) ? favs.remove(id) : favs.add(id);
    _p?.setStringList('favs', favs.toList());
    notifyListeners();
  }

  Future<void> play(String url) async {
    if (url.isEmpty) return;
    try {
      await player.setUrl(Uri.encodeFull(url));
      await player.play();
    } catch (_) {}
  }

  // Score de ressemblance (le plus petit = le mieux). Sert surtout à la recherche vocale :
  // la reconnaissance entend des mots français, on les compare à la colonne "phonétique micro".
  int? fuzzyScore(Entry w, String q) {
    final n = flat(q);
    if (n.length < 2) return null;
    final cands = <String>[flat(w.fr), flat(w.so)];
    for (final p in w.phon.split(',')) {
      cands.add(flat(p));
    }
    final tol = n.length <= 4 ? 1 : 2;
    int? best;
    for (final c in cands) {
      if (c.isEmpty) continue;
      int s;
      if (c == n) {
        s = 0;
      } else if (c.length >= 3 && (c.contains(n) || n.contains(c))) {
        s = 1;
      } else {
        final d = lev(c, n);
        if (d <= tol) {
          s = 1 + d;
        } else {
          continue;
        }
      }
      if (best == null || s < best) best = s;
    }
    return best;
  }

  List<Entry> fuzzy(Iterable<Entry> src, String q) {
    final scored = <MapEntry<Entry, int>>[];
    for (final w in src) {
      final s = fuzzyScore(w, q);
      if (s != null) scored.add(MapEntry(w, s));
    }
    scored.sort((a, b) => a.value.compareTo(b.value));
    return scored.map((e) => e.key).toList();
  }

  List<Entry> search(String q) {
    final n = norm(q);
    if (n.isEmpty) return [];
    final res = words.where((w) {
      return norm(w.fr).contains(n) ||
          norm(w.so).contains(n) ||
          norm(w.phon).contains(n);
    }).toList();
    if (res.isEmpty) return fuzzy(words, q);
    int score(Entry w) {
      if (norm(w.fr) == n || norm(w.so) == n) return 0;
      if (norm(w.fr).startsWith(n) || norm(w.so).startsWith(n)) return 1;
      return 2;
    }

    res.sort((a, b) => score(a).compareTo(score(b)));
    return res;
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
  const SearchField({super.key, required this.hint, required this.onChanged});
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
        ctrl.text = r.recognizedWords;
        ctrl.selection = TextSelection.collapsed(offset: ctrl.text.length);
        widget.onChanged(r.recognizedWords);
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
    return CardShell(
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
    );
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

  @override
  Widget build(BuildContext context) {
    final res = state.search(q);
    final wod = state.words.isEmpty
        ? null
        : state.words[DateTime.now().day % state.words.length];

    return Column(children: [
      GradientHeader(
        title: "Sonink'Écho",
        subtitle: 'Votre traducteur français ⇄ soninké',
        child: SearchField(
            hint: 'Écrire ou dire un mot…', onChanged: (v) => setState(() => q = v)),
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
                      '🎤 Appuyez sur le micro et dites un mot en français ou en soninké.',
                      style: TextStyle(color: Colors.black54)),
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

  @override
  Widget build(BuildContext context) {
    final theme = themeFilter.value;
    final themes = state.words.map((w) => w.theme).where((t) => t.isNotEmpty).toSet().toList()..sort();
    final n = norm(q);
    final pool = state.words.where((w) => theme == null || w.theme == theme).toList();
    var list = n.isEmpty
        ? pool
        : pool
            .where((w) =>
                norm(w.fr).contains(n) || norm(w.so).contains(n) || norm(w.phon).contains(n))
            .toList();
    if (n.isNotEmpty && list.isEmpty) {
      list = state.fuzzy(pool, q);
    } else {
      list.sort((a, b) => norm(frToSo ? a.fr : a.so).compareTo(norm(frToSo ? b.fr : b.so)));
    }

    return Column(children: [
      GradientHeader(
        title: 'Dictionnaire',
        subtitle: frToSo ? 'Français → Soninké' : 'Soninké → Français',
        child: Column(children: [
          SearchField(hint: 'Écrire ou dire un mot…', onChanged: (v) => setState(() => q = v)),
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
  @override
  Widget build(BuildContext context) {
    final n = norm(q);
    final list = state.phrases
        .where((p) => n.isEmpty || norm(p.fr).contains(n) || norm(p.so).contains(n))
        .toList();
    return Column(children: [
      GradientHeader(
        title: 'Phrases utiles',
        subtitle: '${state.phrases.length} phrases du quotidien',
        child: SearchField(
            hint: 'Écrire ou dire une phrase…', onChanged: (v) => setState(() => q = v)),
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
