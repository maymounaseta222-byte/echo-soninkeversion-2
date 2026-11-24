import 'dart:convert';
import 'dart:io';
import 'dart:math';
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

IconData themeIcon(String t) {
  final x = t.toLowerCase();
  if (x.isEmpty) return Icons.more_horiz;
  if (x.contains('animaux')) return Icons.pets;
  if (x.contains('corps')) return Icons.accessibility_new;
  if (x.contains('cole') || x.contains('educ')) return Icons.school;
  if (x.contains('famille')) return Icons.family_restroom;
  if (x.contains('salut')) return Icons.waving_hand;
  if (x.contains('aliment') || x.contains('cuisine') || x.contains('legume') || x.contains('légume')) {
    return Icons.restaurant;
  }
  if (x.contains('couleur')) return Icons.palette;
  if (x.contains('question')) return Icons.help_outline;
  if (x.contains('politesse')) return Icons.favorite_border;
  if (x.contains('quotidien')) return Icons.wb_sunny_outlined;
  if (x.contains('logement') || x.contains('maison')) return Icons.home_outlined;
  if (x.contains('admin')) return Icons.description_outlined;
  if (x.contains('sant')) return Icons.local_hospital_outlined;
  if (x.contains('travail') || x.contains('metier')) return Icons.work_outline;
  if (x.contains('march') || x.contains('argent')) return Icons.shopping_bag_outlined;
  if (x.contains('transport') || x.contains('voyage')) return Icons.directions_bus_outlined;
  if (x.contains('nombre') || x.contains('chiffre')) return Icons.numbers;
  if (x.contains('temps') || x.contains('date')) return Icons.schedule;
  if (x.contains('nature') || x.contains('meteo')) return Icons.park_outlined;
  return Icons.label_outline;
}

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
  double textScale = 1.0;
  bool slow = false;
  int _playId = 0;

  // Apprentissage vocal : ce que le micro a entendu -> le bon mot
  final Map<String, Set<String>> learned = {};
  final List<String> learnedRaw = [];
  List<String> lastHeard = [];

  static const wordsUrl =
      'https://docs.google.com/spreadsheets/d/e/2PACX-1vRocmShHz4hOvK8VgfrdpjWbs2mipSrv-CZ4G_KzcHlBY9-5C_bpy3RFsclIpfJadVnPWlhvBKwtOTv/pub?gid=1122578490&single=true&output=csv';
  static const phrasesUrl =
      'https://docs.google.com/spreadsheets/d/e/2PACX-1vRocmShHz4hOvK8VgfrdpjWbs2mipSrv-CZ4G_KzcHlBY9-5C_bpy3RFsclIpfJadVnPWlhvBKwtOTv/pub?gid=916562575&single=true&output=csv';

  // Lecteur CSV (gère guillemets, virgules et retours à la ligne dans les cellules)
  static List<Map<String, dynamic>> parseCsv(String t) {
    final rows = <List<String>>[];
    var row = <String>[];
    final f = StringBuffer();
    var q = false;
    if (t.isNotEmpty && t.codeUnitAt(0) == 0xFEFF) t = t.substring(1);
    for (var i = 0; i < t.length; i++) {
      final c = t[i];
      if (q) {
        if (c == '"') {
          if (i + 1 < t.length && t[i + 1] == '"') {
            f.write('"');
            i++;
          } else {
            q = false;
          }
        } else {
          f.write(c);
        }
      } else if (c == '"') {
        q = true;
      } else if (c == ',') {
        row.add(f.toString());
        f.clear();
      } else if (c == '\n' || c == '\r') {
        if (c == '\r' && i + 1 < t.length && t[i + 1] == '\n') i++;
        row.add(f.toString());
        f.clear();
        rows.add(row);
        row = <String>[];
      } else {
        f.write(c);
      }
    }
    if (f.isNotEmpty || row.isNotEmpty) {
      row.add(f.toString());
      rows.add(row);
    }
    if (rows.length < 2) return [];
    final head = rows.first.map((h) => h.trim()).toList();
    final out = <Map<String, dynamic>>[];
    for (final r in rows.skip(1)) {
      final m = <String, dynamic>{};
      for (var i = 0; i < head.length && i < r.length; i++) {
        if (head[i].isNotEmpty) m[head[i]] = r[i];
      }
      out.add(m);
    }
    return out;
  }

  Future<String?> _download(String url) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await c.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return null;
      return await utf8.decoder.bind(res).join().timeout(const Duration(seconds: 30));
    } catch (_) {
      return null;
    } finally {
      c.close(force: true);
    }
  }

  void _setWords(List rows) {
    final m = <String, Entry>{};
    for (final x in rows) {
      final e = Entry(Map<String, dynamic>.from(x));
      if (e.fr.isEmpty || e.so.isEmpty) continue;
      final k = '${norm(e.fr)}|${norm(e.so)}';
      final o = m[k];
      if (o == null || infoCount(e) > infoCount(o)) m[k] = e;
    }
    words = m.values.toList();
    byId = {for (final e in words) e.id: e};
  }

  void _setPhrases(List rows) {
    final pm = <String, Phrase>{};
    for (final x in rows) {
      final p = Phrase(Map<String, dynamic>.from(x));
      if (p.fr.isEmpty || p.so.isEmpty) continue;
      pm['${norm(p.fr)}|${norm(p.so)}'] = p;
    }
    phrases = pm.values.toList();
  }

  Future<void> load() async {
    try {
      _p = await SharedPreferences.getInstance();
    } catch (_) {}
    // 1) données livrées avec l'appli (secours hors-ligne)
    List bundledWords = [];
    final List bundledPhrases = [];
    try {
      final j = jsonDecode(await rootBundle.loadString('assets/data/data.json'));
      bundledWords = j is List ? j : (j['words'] ?? j['mots'] ?? []);
      if (j is Map && j['phrases'] is List) bundledPhrases.addAll(j['phrases'] as List);
    } catch (e) {
      error = 'Impossible de lire assets/data/data.json : $e';
    }
    try {
      final j2 = jsonDecode(await rootBundle.loadString('assets/data/phrases.json'));
      bundledPhrases.addAll(j2 is List ? j2 : (j2['phrases'] ?? []));
    } catch (_) {}
    // 2) dernière copie du Sheet gardée sur le téléphone (sinon données livrées)
    List cachedWords = [];
    List cachedPhrases = [];
    try {
      final cw = _p?.getString('cache_words');
      final cp = _p?.getString('cache_phrases');
      if (cw != null) cachedWords = jsonDecode(cw) as List;
      if (cp != null) cachedPhrases = jsonDecode(cp) as List;
    } catch (_) {}
    _setWords(cachedWords.length >= 20 ? cachedWords : bundledWords);
    _setPhrases(cachedPhrases.isNotEmpty ? cachedPhrases : bundledPhrases);
    if (words.isEmpty && error == null) {
      error = "Aucun mot trouvé (vérifiez les noms de colonnes).";
    }
    // 3) favoris et apprentissage
    try {
      textScale = _p?.getDouble('tscale') ?? 1.0;
      slow = _p?.getBool('slow') ?? false;
      favs = (_p?.getStringList('favs') ?? []).toSet();
      for (final rec in _p?.getStringList('learned') ?? <String>[]) {
        final parts = rec.split('\t');
        if (parts.length < 2) continue;
        learnedRaw.add(rec);
        learned.putIfAbsent(phoKey(parts[0]), () => <String>{}).add(parts[1]);
      }
    } catch (_) {}
    loaded = true;
    notifyListeners();
    // 4) mise à jour silencieuse depuis le Google Sheet
    _sync();
  }

  Future<void> _sync() async {
    try {
      final w = await _download(wordsUrl);
      if (w != null) {
        final rows = parseCsv(w);
        final ok = rows.where((r) => Entry(r).fr.isNotEmpty && Entry(r).so.isNotEmpty).length;
        if (ok >= 20) {
          _setWords(rows);
          error = null;
          await _p?.setString('cache_words', jsonEncode(rows));
        }
      }
      final p = await _download(phrasesUrl);
      if (p != null) {
        final rows = parseCsv(p);
        final ok = rows.where((r) => Phrase(r).fr.isNotEmpty && Phrase(r).so.isNotEmpty).length;
        if (ok >= 1) {
          _setPhrases(rows);
          await _p?.setString('cache_phrases', jsonEncode(rows));
        }
      }
      notifyListeners();
    } catch (_) {}
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

  void setScale(double v) {
    textScale = v;
    _p?.setDouble('tscale', v);
    notifyListeners();
  }

  void setSlow(bool v) {
    slow = v;
    _p?.setBool('slow', v);
    notifyListeners();
  }

  Future<void> _play(String url) async {
    if (url.isEmpty) return;
    try {
      await player.stop();
      await player.setUrl(Uri.encodeFull(url));
      await player.setSpeed(slow ? 0.7 : 1.0);
      await player.play();
    } catch (_) {}
  }

  Future<void> play(String url) async {
    _playId++;
    await _play(url);
  }

  // Français puis soninké, d'un seul appui
  Future<void> playBoth(Entry e, {bool soFirst = false}) async {
    final id = ++_playId;
    await _play(soFirst ? e.audioSo : e.audioFr);
    if (id != _playId) return;
    await _play(soFirst ? e.audioFr : e.audioSo);
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
final tabNotifier = ValueNotifier<int>(0);
final micOn = ValueNotifier<bool>(false);

// ---------- Application ----------
class SoninkeEchoApp extends StatelessWidget {
  const SoninkeEchoApp({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: state,
      builder: (context, _) => MaterialApp(
        title: "Sonink'Écho",
        debugShowCheckedModeBanner: false,
        builder: (c, child) => MediaQuery(
          data: MediaQuery.of(c).copyWith(
              textScaler: TextScaler.linear(
                  MediaQuery.textScalerOf(c).scale(1.0) * state.textScale)),
          child: child!,
        ),
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: violet),
          scaffoldBackgroundColor: fond,
          useMaterial3: true,
        ),
        home: const Home(),
      ));
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

  void _tabChanged() {
    if (mounted) setState(() => tab = tabNotifier.value);
  }

  @override
  void initState() {
    super.initState();
    state.addListener(_rebuild);
    tabNotifier.addListener(_tabChanged);
    state.load();
  }

  @override
  void dispose() {
    state.removeListener(_rebuild);
    tabNotifier.removeListener(_tabChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const SearchPage(),
      const ThemesPage(),
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
      bottomNavigationBar: SafeArea(
        child: _NavBar(tab: tab, onTap: (i) => tabNotifier.value = i),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  final Color color;
  const _NavItem(this.icon, this.label, this.color);
}

const _navItems = [
  _NavItem(Icons.record_voice_over_rounded, 'Traduire', violet),
  _NavItem(Icons.category_rounded, 'Thèmes', orange),
  _NavItem(Icons.menu_book_rounded, 'Dictionnaire', Color(0xFF2979FF)),
  _NavItem(Icons.forum_rounded, 'Phrases', turquoise),
  _NavItem(Icons.favorite_rounded, 'Favoris', Color(0xFFE91E63)),
];

class _NavBar extends StatelessWidget {
  final int tab;
  final ValueChanged<int> onTap;
  const _NavBar({required this.tab, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(color: violet.withValues(alpha: 0.18), blurRadius: 18, offset: const Offset(0, 4))
        ],
      ),
      child: Row(children: [
        for (var i = 0; i < _navItems.length; i++)
          Expanded(
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
                decoration: BoxDecoration(
                  color: i == tab
                      ? _navItems[i].color.withValues(alpha: 0.14)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_navItems[i].icon,
                      size: i == tab ? 30 : 26,
                      color: i == tab
                          ? _navItems[i].color
                          : _navItems[i].color.withValues(alpha: 0.55)),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(_navItems[i].label,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: i == tab ? FontWeight.w800 : FontWeight.w600,
                            color: i == tab ? _navItems[i].color : Colors.black54)),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

// ---------- Composants ----------
class GradientHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? child;
  final VoidCallback? onBack;
  final Widget? trailing;
  const GradientHeader(
      {super.key, required this.title, this.subtitle, this.child, this.onBack, this.trailing});

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
            if (onBack != null)
              InkWell(
                onTap: onBack,
                borderRadius: BorderRadius.circular(20),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.arrow_back, color: Colors.white, size: 28),
                ),
              )
            else
              const Icon(Icons.graphic_eq, color: Colors.white, size: 28),
            const SizedBox(width: 8),
            Text(title,
                style: const TextStyle(
                    color: Colors.white, fontSize: 24, fontWeight: FontWeight.w800)),
            const Spacer(),
            if (trailing != null) trailing!,
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
    micOn.value = false;
    stt.cancel();
    ctrl.dispose();
    super.dispose();
  }

  void _setL(bool v) {
    micOn.value = v;
    if (mounted) setState(() => listening = v);
  }

  Future<void> toggleMic() async {
    if (listening) {
      await stt.stop();
      _setL(false);
      return;
    }
    if (!ready) {
      try {
        ready = await stt.initialize(
          onStatus: (s) {
            if (s == 'done' || s == 'notListening') _setL(false);
          },
          onError: (e) {
            _setL(false);
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
    _setL(true);
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

// Gros bouton rond : la langue connue d'abord, puis la langue à apprendre
class PlayBtn extends StatelessWidget {
  final Entry e;
  final bool soKnown;
  final double size;
  const PlayBtn(this.e, {super.key, this.soKnown = false, this.size = 56});
  @override
  Widget build(BuildContext context) {
    final has = e.audioFr.isNotEmpty || e.audioSo.isNotEmpty;
    return InkWell(
      customBorder: const CircleBorder(),
      onTap: has ? () => state.playBoth(e, soFirst: soKnown) : null,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: has ? degrade : null,
          color: has ? null : Colors.grey.shade300,
        ),
        child: Icon(Icons.volume_up_rounded, color: Colors.white, size: size * 0.55),
      ),
    );
  }
}

// soKnown = true : l'utilisateur cherche depuis le soninké (mot soninké petit, français en gros)
class WordTile extends StatelessWidget {
  final Entry e;
  final bool soKnown;
  const WordTile(this.e, {super.key, this.soKnown = false});
  @override
  Widget build(BuildContext context) {
    final big = soKnown ? e.fr : e.so;
    final small = soKnown ? e.so : e.fr;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () {
        if (state.lastHeard.isNotEmpty) {
          final h = List<String>.from(state.lastHeard);
          state.lastHeard = [];
          state.learn(e, h);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Retenu : « ${h.first} » = ${e.so}')));
          return;
        }
        Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => WordDetailPage(e, soKnown: soKnown)));
      },
      child: CardShell(
        color: violet,
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(big,
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w800, color: violet)),
              const SizedBox(height: 2),
              Text(small, style: const TextStyle(fontSize: 14, color: Colors.black54)),
            ]),
          ),
          PlayBtn(e, soKnown: soKnown),
          FavBtn(e.id),
        ]),
      ),
    );
  }
}

List<Widget> _audioPair(Entry e, bool soKnown) {
  final so = _BigAudio('Écouter en soninké', const Color(0xFF00A86B), e.audioSo);
  final fr = _BigAudio('Écouter en français', const Color(0xFF2979FF), e.audioFr);
  return soKnown
      ? [so, const SizedBox(height: 12), fr]
      : [fr, const SizedBox(height: 12), so];
}

class _BigAudio extends StatelessWidget {
  final String label;
  final Color color;
  final String url;
  const _BigAudio(this.label, this.color, this.url);
  @override
  Widget build(BuildContext context) {
    final has = url.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(22),
      onTap: has ? () => state.play(url) : null,
      child: Container(
        height: 68,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: has ? color : Colors.grey.shade300,
          borderRadius: BorderRadius.circular(22),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.volume_up_rounded, color: Colors.white, size: 32),
          const SizedBox(width: 10),
          Text(has ? label : 'Audio bientôt disponible',
              style: const TextStyle(
                  color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
        ]),
      ),
    );
  }
}

// ---------- Fiche d'un mot ----------
class WordDetailPage extends StatelessWidget {
  final Entry e;
  final bool soKnown;
  const WordDetailPage(this.e, {super.key, this.soKnown = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final fr = norm(e.fr);
          final ex = fr.length < 3
              ? <Phrase>[]
              : state.phrases.where((p) => norm(p.fr).contains(fr)).take(3).toList();
          return Column(children: [
            GradientHeader(
              title: e.theme.isEmpty ? 'Mot' : cap(e.theme),
              onBack: () => Navigator.of(context).pop(),
            ),
            Expanded(
              child: ListView(padding: const EdgeInsets.all(16), children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 24, 12, 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    boxShadow: [
                      BoxShadow(
                          color: violet.withValues(alpha: 0.14),
                          blurRadius: 14,
                          offset: const Offset(0, 5))
                    ],
                  ),
                  child: Column(children: [
                    Text(soKnown ? e.fr : e.so,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 38, fontWeight: FontWeight.w800, color: violet)),
                    const SizedBox(height: 8),
                    Text(soKnown ? e.so : e.fr,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 20, color: Colors.black54)),
                    Align(alignment: Alignment.centerRight, child: FavBtn(e.id)),
                  ]),
                ),
                const SizedBox(height: 16),
                ..._audioPair(e, soKnown),
                const SizedBox(height: 12),
                InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () => state.setSlow(!state.slow),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: state.slow ? const Color(0xFFFFF1D6) : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                          color: state.slow ? orange : const Color(0xFFD9D2EE)),
                    ),
                    child: Row(children: [
                      const Text('🐢', style: TextStyle(fontSize: 26)),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text('Écouter lentement',
                            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                      Switch(value: state.slow, onChanged: state.setSlow),
                    ]),
                  ),
                ),
                if (ex.isNotEmpty) ...[
                  const Padding(
                    padding: EdgeInsets.fromLTRB(4, 22, 0, 4),
                    child: Text('Dans une phrase',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  ),
                  for (final p in ex) PhraseTile(p),
                ],
              ]),
            ),
          ]);
        },
      ),
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

// ---------- Réglages (taille du texte, vitesse audio) ----------
class _Choice extends StatelessWidget {
  final String label;
  final bool on;
  final double size;
  final VoidCallback tap;
  const _Choice(this.label, this.on, this.tap, {this.size = 16});
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: tap,
          child: Container(
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? violet : Colors.white,
              border: Border.all(color: on ? violet : const Color(0xFFD9D2EE)),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: size,
                    fontWeight: FontWeight.w800,
                    color: on ? Colors.white : const Color(0xFF5A4E80))),
          ),
        ),
      ),
    );
  }
}

void showSettings(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: fond,
    builder: (_) => ListenableBuilder(
      listenable: state,
      builder: (c, _) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 28),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Taille du texte',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(children: [
            _Choice('A', state.textScale == 1.0, () => state.setScale(1.0), size: 16),
            _Choice('A+', state.textScale == 1.2, () => state.setScale(1.2), size: 20),
            _Choice('A++', state.textScale == 1.4, () => state.setScale(1.4), size: 24),
          ]),
          const SizedBox(height: 22),
          const Text("Vitesse de l'audio",
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(children: [
            _Choice('Normal', !state.slow, () => state.setSlow(false)),
            _Choice('Lent 🐢', state.slow, () => state.setSlow(true)),
          ]),
        ]),
      ),
    ),
  );
}

// ---------- Page Traduire ----------
class _BigMic extends StatelessWidget {
  final VoidCallback onTap;
  const _BigMic({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: micOn,
      builder: (context, on, _) => Column(children: [
        InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: on
                  ? const LinearGradient(colors: [Color(0xFFE53935), Color(0xFFFF7043)])
                  : degrade,
              boxShadow: [
                BoxShadow(
                    color: (on ? Colors.red : violet).withValues(alpha: 0.35),
                    blurRadius: on ? 30 : 18,
                    spreadRadius: on ? 6 : 0,
                    offset: const Offset(0, 6))
              ],
            ),
            child: Icon(on ? Icons.hearing : Icons.mic, color: Colors.white, size: 60),
          ),
        ),
        const SizedBox(height: 12),
        Text(on ? 'Je vous écoute…' : 'Touchez et parlez',
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: violet)),
        const SizedBox(height: 2),
        const Text('en français ou en soninké',
            style: TextStyle(fontSize: 15, color: Colors.black54)),
      ]),
    );
  }
}

class _Shortcut extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final int tab;
  const _Shortcut(this.icon, this.label, this.color, this.tab);
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => tabNotifier.value = tab,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: color.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 4))
              ],
            ),
            child: Column(children: [
              Icon(icon, color: color, size: 36),
              const SizedBox(height: 6),
              Text(label,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: color)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _WordOfDay extends StatelessWidget {
  final Entry e;
  const _WordOfDay(this.e);
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => WordDetailPage(e))),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: violet.withValues(alpha: 0.35), width: 1.5),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('✨ Mot du jour',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: orange)),
              const SizedBox(height: 2),
              Text(e.so,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: violet)),
              Text(e.fr, style: const TextStyle(fontSize: 14, color: Colors.black54)),
            ]),
          ),
          PlayBtn(e, size: 44),
        ]),
      ),
    );
  }
}

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String q = '';
  List<String> alts = [];
  bool voice = false;
  final fieldKey = GlobalKey<_SearchFieldState>();

  // true si la personne est partie d'un mot soninké
  bool soKnownFor(Entry e) {
    final qs = [q, ...alts].map(norm).where((x) => x.isNotEmpty).toList();
    final frHit = qs.any((n) => norm(e.fr).contains(n));
    final soHit = qs.any((n) =>
        norm(e.so).contains(n) || (e.phon.isNotEmpty && norm(e.phon).contains(n)));
    if (soHit && !frHit) return true;
    if (frHit) return false;
    return voice; // proche au son : le micro a entendu du soninké
  }

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
        trailing: IconButton(
          tooltip: 'Réglages',
          icon: const Icon(Icons.text_fields_rounded, color: Colors.white, size: 28),
          onPressed: () => showSettings(context),
        ),
        child: SearchField(
          key: fieldKey,
          hint: 'Écrire ou dire un mot…',
          onChanged: (v) {
            state.lastHeard = [];
            setState(() {
              voice = false;
              q = v;
              alts = [];
            });
          },
          onVoice: (a) {
            state.lastHeard = a;
            setState(() {
              voice = true;
              q = a.first;
              alts = a;
            });
          },
        ),
      ),
      Expanded(
        child: q.trim().isNotEmpty
            ? (res.isEmpty
                ? const Center(child: Text('Aucun résultat 🤔', style: TextStyle(fontSize: 18)))
                : ListView(padding: const EdgeInsets.only(top: 10), children: [
                    if (state.lastHeard.isNotEmpty)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                        child: Text(
                            "Le micro s'est trompé ? Touchez le bon mot : l'appli apprend. 👆",
                            style: TextStyle(color: Colors.black54, fontSize: 14)),
                      ),
                    for (final e in res) WordTile(e, soKnown: soKnownFor(e)),
                  ]))
            : ListView(padding: const EdgeInsets.only(top: 22, bottom: 16), children: [
                _BigMic(onTap: () => fieldKey.currentState?.toggleMic()),
                const SizedBox(height: 24),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () => openQuiz(context, 'Quiz du jour', state.words, 5),
                    child: Container(
                      height: 62,
                      decoration: BoxDecoration(
                        gradient: degrade,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(Icons.emoji_events_rounded, color: Colors.white, size: 30),
                        SizedBox(width: 10),
                        Text('Quiz du jour',
                            style: TextStyle(
                                color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
                      ]),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                if (wod != null) _WordOfDay(wod),
                if (state.learnedRaw.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
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
                itemCount: list.length,
                itemBuilder: (_, i) => WordTile(list[i], soKnown: !frToSo)),
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

// ---------- Quiz : j'entends un mot soninké, je choisis sa traduction ----------
class _QItem {
  final Entry answer;
  final List<Entry> options;
  _QItem(this.answer, this.options);
}

List<_QItem> buildQuiz(List<Entry> pool, int n) {
  final rnd = Random();
  final base = pool.length >= 4 ? pool : state.words;
  final cands = pool.where((e) => e.audioSo.isNotEmpty).toList()..shuffle(rnd);
  final out = <_QItem>[];
  for (final a in cands) {
    if (out.length >= n) break;
    final others = base.where((e) => norm(e.fr) != norm(a.fr)).toList()..shuffle(rnd);
    final seen = <String>{norm(a.fr)};
    final opts = <Entry>[a];
    for (final o in others) {
      if (opts.length >= 4) break;
      if (seen.add(norm(o.fr))) opts.add(o);
    }
    if (opts.length < 4) continue;
    opts.shuffle(rnd);
    out.add(_QItem(a, opts));
  }
  return out;
}

void openQuiz(BuildContext context, String title, List<Entry> pool, int n) {
  if (buildQuiz(pool, 1).isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Pas encore assez de mots avec audio pour faire un quiz ici.")));
    return;
  }
  Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => QuizPage(title: title, pool: pool, count: n)));
}

class QuizPage extends StatefulWidget {
  final String title;
  final List<Entry> pool;
  final int count;
  const QuizPage({super.key, required this.title, required this.pool, required this.count});
  @override
  State<QuizPage> createState() => _QuizPageState();
}

class _QuizPageState extends State<QuizPage> {
  late List<_QItem> items;
  int i = 0;
  int score = 0;
  Entry? picked;
  bool done = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    items = buildQuiz(widget.pool, widget.count);
    i = 0;
    score = 0;
    picked = null;
    done = items.isEmpty;
    if (items.isNotEmpty) state.play(items[0].answer.audioSo);
  }

  void _answer(Entry o) {
    final a = items[i].answer;
    setState(() {
      picked = o;
      if (o == a) score++;
    });
    state.play(a.audioFr);
  }

  void _next() {
    if (i + 1 >= items.length) {
      setState(() => done = true);
      return;
    }
    setState(() {
      i++;
      picked = null;
    });
    state.play(items[i].answer.audioSo);
  }

  Widget _answerBtn(Entry o) {
    final a = items[i].answer;
    Color bg = Colors.white;
    Color fg = const Color(0xFF3B2F66);
    Color border = const Color(0xFFD9D2EE);
    if (picked != null) {
      if (o == a) {
        bg = const Color(0xFF2E9E5B);
        fg = Colors.white;
        border = bg;
      } else if (o == picked) {
        bg = const Color(0xFFE53935);
        fg = Colors.white;
        border = bg;
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: picked == null ? () => _answer(o) : null,
        child: Container(
          height: 66,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: border, width: 2),
          ),
          child: Text(cap(o.fr),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: fg)),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final total = items.length;
    return Scaffold(
      body: Column(children: [
        GradientHeader(
          title: widget.title,
          subtitle: done ? 'Terminé' : 'Question ${i + 1} sur $total',
          onBack: () => Navigator.of(context).pop(),
        ),
        if (!done)
          LinearProgressIndicator(
              value: (i + (picked != null ? 1 : 0)) / total,
              minHeight: 6,
              color: turquoise,
              backgroundColor: const Color(0xFFE6E0F7)),
        Expanded(child: done ? _result(total) : _question()),
      ]),
    );
  }

  Widget _question() {
    final q = items[i];
    final ok = picked == q.answer;
    return ListView(padding: const EdgeInsets.all(16), children: [
      const SizedBox(height: 8),
      const Text('Écoutez, puis choisissez la bonne réponse',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      const SizedBox(height: 18),
      Center(
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => state.play(q.answer.audioSo),
          child: Container(
            width: 112,
            height: 112,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: degrade,
              boxShadow: [
                BoxShadow(color: violet.withValues(alpha: 0.35), blurRadius: 18, offset: const Offset(0, 6))
              ],
            ),
            child: const Icon(Icons.volume_up_rounded, color: Colors.white, size: 58),
          ),
        ),
      ),
      const SizedBox(height: 22),
      for (final o in q.options) _answerBtn(o),
      if (picked != null) ...[
        const SizedBox(height: 4),
        Text(
            ok
                ? '✅ Bravo !'
                : 'Ce n\'était pas ça. La bonne réponse : ${cap(q.answer.fr)} (${q.answer.so})',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: ok ? const Color(0xFF2E9E5B) : const Color(0xFFE53935))),
        const SizedBox(height: 12),
        InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: _next,
          child: Container(
            height: 62,
            alignment: Alignment.center,
            decoration: BoxDecoration(gradient: degrade, borderRadius: BorderRadius.circular(20)),
            child: Text(i + 1 >= items.length ? 'Voir mon score' : 'Suivant  ➜',
                style: const TextStyle(
                    color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    ]);
  }

  Widget _result(int total) {
    final good = total > 0 && score * 2 >= total;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(total == 0 ? '🤔' : (good ? '🎉' : '💪'), style: const TextStyle(fontSize: 72)),
          const SizedBox(height: 8),
          Text(total == 0 ? 'Pas de quiz possible' : (good ? 'Bravo !' : 'Continuez, ça vient !'),
              style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: violet)),
          const SizedBox(height: 8),
          Text('$score / $total',
              style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
          const SizedBox(height: 28),
          InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => setState(_start),
            child: Container(
              height: 62,
              width: double.infinity,
              alignment: Alignment.center,
              decoration: BoxDecoration(gradient: degrade, borderRadius: BorderRadius.circular(20)),
              child: const Text('Rejouer',
                  style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Terminer', style: TextStyle(fontSize: 18)),
          ),
        ]),
      ),
    );
  }
}

// ---------- Page Thèmes ----------
class ThemesPage extends StatelessWidget {
  const ThemesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final w in state.words) {
      counts[w.theme] = (counts[w.theme] ?? 0) + 1;
    }
    final names = counts.keys.where((t) => t.isNotEmpty).toList()..sort();
    final items = <String>[...names, if ((counts[''] ?? 0) > 0) ''];

    return Column(children: [
      GradientHeader(
        title: 'Thèmes',
        subtitle: '${names.length} thèmes · ${state.words.length} mots',
      ),
      Expanded(
        child: GridView.count(
          crossAxisCount: 2,
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.9,
          children: [
            for (final t in items) _ThemeCard(theme: t, count: counts[t] ?? 0),
          ],
        ),
      ),
    ]);
  }
}

class _ThemeCard extends StatelessWidget {
  final String theme;
  final int count;
  const _ThemeCard({required this.theme, required this.count});

  @override
  Widget build(BuildContext context) {
    final label = theme.isEmpty ? 'Autres' : cap(theme);
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ThemeDetailPage(theme: theme)),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(color: violet.withValues(alpha: 0.10), blurRadius: 10, offset: const Offset(0, 4))
          ],
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(9),
              decoration: BoxDecoration(
                color: violet.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(themeIcon(theme), color: violet, size: 24),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    Text('$count ${count > 1 ? 'mots' : 'mot'}',
                        style: const TextStyle(fontSize: 13, color: Colors.black54)),
                  ]),
            ),
          ],
        ),
      ),
    );
  }
}

class ThemeDetailPage extends StatelessWidget {
  final String theme;
  const ThemeDetailPage({super.key, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: state,
        builder: (context, _) {
          final list = state.words.where((w) => w.theme == theme).toList()
            ..sort((a, b) => norm(a.fr).compareTo(norm(b.fr)));
          return Column(children: [
            GradientHeader(
              title: theme.isEmpty ? 'Autres' : cap(theme),
              subtitle: '${list.length} ${list.length > 1 ? 'mots' : 'mot'}',
              onBack: () => Navigator.of(context).pop(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.play_circle_fill_rounded, size: 22),
                  label: const Text("S'entraîner (quiz)", style: TextStyle(fontSize: 16)),
                  onPressed: () => openQuiz(
                      context, theme.isEmpty ? 'Autres' : cap(theme), list, 8),
                ),
              ),
            ),
            Expanded(
              child: list.isEmpty
                  ? const Center(child: Text('Aucun mot dans ce thème'))
                  : ListView.builder(
                      padding: const EdgeInsets.only(top: 6, bottom: 10),
                      itemCount: list.length,
                      itemBuilder: (_, i) => WordTile(list[i]),
                    ),
            ),
          ]);
        },
      ),
    );
  }
}
