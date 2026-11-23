import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const SoninkeEchoApp());

// ---------- Couleurs ----------
const violet = Color(0xFF6A3DE8);
const rose = Color(0xFFE040FB);
const orange = Color(0xFFFF7A00);
const turquoise = Color(0xFF00B8A9);
const fond = Color(0xFFF5F2FF);

const palette = [
  Color(0xFF7C4DFF),
  Color(0xFFFF6D00),
  Color(0xFF00BFA5),
  Color(0xFFE91E63),
  Color(0xFF2979FF),
  Color(0xFFFFAB00),
  Color(0xFF43A047),
  Color(0xFFD500F9),
];

Color themeColor(String t) {
  if (t.isEmpty) return violet;
  var s = 0;
  for (final c in t.codeUnits) {
    s += c;
  }
  return palette[s % palette.length];
}

IconData themeIcon(String t) {
  final x = t.toLowerCase();
  if (x.contains('animaux')) return Icons.pets;
  if (x.contains('corps')) return Icons.accessibility_new;
  if (x.contains('cole')) return Icons.school;
  if (x.contains('famille')) return Icons.family_restroom;
  if (x.contains('salut')) return Icons.waving_hand;
  if (x.contains('aliment') || x.contains('cuisine')) return Icons.restaurant;
  if (x.contains('couleur')) return Icons.palette;
  if (x.contains('question')) return Icons.help_outline;
  if (x.contains('politesse')) return Icons.favorite;
  if (x.contains('quotidien')) return Icons.wb_sunny;
  if (x.contains('logement')) return Icons.home;
  return Icons.label;
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

  List<Entry> search(String q) {
    final n = norm(q);
    if (n.isEmpty) return [];
    final res = words.where((w) {
      return norm(w.fr).contains(n) ||
          norm(w.so).contains(n) ||
          norm(w.phon).contains(n);
    }).toList();
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
      SearchPage(onTheme: (t) {
        themeFilter.value = t;
        setState(() => tab = 1);
      }),
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
      bottomNavigationBar: NavigationBar(
        backgroundColor: Colors.white,
        indicatorColor: violet.withValues(alpha: 0.18),
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.translate), selectedIcon: Icon(Icons.translate, color: violet), label: 'Traduire'),
          NavigationDestination(
              icon: Icon(Icons.menu_book_outlined), selectedIcon: Icon(Icons.menu_book, color: orange), label: 'Dictionnaire'),
          NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble, color: turquoise), label: 'Phrases'),
          NavigationDestination(
              icon: Icon(Icons.star_border), selectedIcon: Icon(Icons.star, color: Colors.amber), label: 'Favoris'),
        ],
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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [violet, Color(0xFFAB47BC), Color(0xFFFF7043)],
        ),
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

class SearchField extends StatelessWidget {
  final String hint;
  final ValueChanged<String> onChanged;
  const SearchField({super.key, required this.hint, required this.onChanged});
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
        onChanged: onChanged,
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search, color: violet),
          hintText: hint,
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(vertical: 14),
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
          BoxShadow(color: color.withValues(alpha: 0.2), blurRadius: 12, offset: const Offset(0, 4))
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
    final c = themeColor(e.theme);
    return CardShell(
      color: c,
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
                    color: c.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(10)),
                child: Text(cap(e.theme),
                    style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
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
  final int i;
  const PhraseTile(this.p, this.i, {super.key});
  @override
  Widget build(BuildContext context) {
    final c = palette[i % palette.length];
    return CardShell(
      color: c,
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(p.so,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: c)),
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
  final ValueChanged<String?> onTheme;
  const SearchPage({super.key, required this.onTheme});
  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  String q = '';

  @override
  Widget build(BuildContext context) {
    final res = state.search(q);
    final themes = state.words.map((w) => w.theme).where((t) => t.isNotEmpty).toSet().toList()..sort();
    final wod = state.words.isEmpty
        ? null
        : state.words[DateTime.now().day % state.words.length];

    return Column(children: [
      GradientHeader(
        title: "Sonink'Écho",
        subtitle: 'Votre traducteur français ⇄ soninké',
        child: SearchField(
            hint: 'Taper un mot en français ou en soninké…',
            onChanged: (v) => setState(() => q = v)),
      ),
      Expanded(
        child: q.isNotEmpty
            ? (res.isEmpty
                ? const Center(child: Text('Aucun résultat 🤔'))
                : ListView(padding: const EdgeInsets.only(top: 10), children: [for (final e in res) WordTile(e)]))
            : ListView(padding: const EdgeInsets.all(16), children: [
                Row(children: [
                  Expanded(
                      child: _Stat('${state.words.length}', 'Mots', turquoise, Icons.abc)),
                  const SizedBox(width: 12),
                  Expanded(
                      child: _Stat('${state.phrases.length}', 'Phrases', orange, Icons.chat)),
                ]),
                const SizedBox(height: 20),
                if (wod != null) ...[
                  const Text('✨ Mot du jour',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                  const SizedBox(height: 4),
                  Transform.translate(
                      offset: const Offset(-16, 0),
                      child: SizedBox(
                          width: MediaQuery.of(context).size.width, child: WordTile(wod))),
                ],
                const SizedBox(height: 12),
                const Text('Parcourir par thème',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Wrap(spacing: 10, runSpacing: 10, children: [
                  for (final t in themes)
                    InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => widget.onTheme(t),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: themeColor(t),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(themeIcon(t), color: Colors.white, size: 18),
                          const SizedBox(width: 6),
                          Text(cap(t),
                              style: const TextStyle(
                                  color: Colors.white, fontWeight: FontWeight.w700)),
                        ]),
                      ),
                    ),
                ]),
              ]),
      ),
    ]);
  }
}

class _Stat extends StatelessWidget {
  final String n, label;
  final Color color;
  final IconData icon;
  const _Stat(this.n, this.label, this.color, this.icon);
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [color, color.withValues(alpha: 0.7)]),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(children: [
        Icon(icon, color: Colors.white, size: 34),
        const SizedBox(width: 10),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(n,
              style: const TextStyle(
                  color: Colors.white, fontSize: 26, fontWeight: FontWeight.w900)),
          Text(label, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ]),
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

  void _r() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    themeFilter.addListener(_r);
  }

  @override
  void dispose() {
    themeFilter.removeListener(_r);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = themeFilter.value;
    final themes = state.words.map((w) => w.theme).where((t) => t.isNotEmpty).toSet().toList()..sort();
    final n = norm(q);
    var list = state.words.where((w) {
      if (theme != null && w.theme != theme) return false;
      if (n.isEmpty) return true;
      return norm(w.fr).contains(n) || norm(w.so).contains(n) || norm(w.phon).contains(n);
    }).toList();
    list.sort((a, b) => norm(frToSo ? a.fr : a.so).compareTo(norm(frToSo ? b.fr : b.so)));

    return Column(children: [
      GradientHeader(
        title: 'Dictionnaire',
        subtitle: frToSo ? 'Français → Soninké' : 'Soninké → Français',
        child: Column(children: [
          SearchField(hint: 'Rechercher un mot…', onChanged: (v) => setState(() => q = v)),
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
            _Chip('Tous', null, theme == null, violet, () => themeFilter.value = null),
            for (final t in themes)
              _Chip(cap(t), themeIcon(t), theme == t, themeColor(t), () => themeFilter.value = t),
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
  final IconData? icon;
  final bool on;
  final Color color;
  final VoidCallback tap;
  const _Chip(this.label, this.icon, this.on, this.color, this.tap);
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
            color: on ? color : Colors.white,
            border: Border.all(color: color, width: 1.5),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(children: [
            if (icon != null) ...[
              Icon(icon, size: 16, color: on ? Colors.white : color),
              const SizedBox(width: 5),
            ],
            Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w700, color: on ? Colors.white : color)),
          ]),
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
        child: SearchField(hint: 'Rechercher une phrase…', onChanged: (v) => setState(() => q = v)),
      ),
      Expanded(
        child: ListView.builder(
          padding: const EdgeInsets.only(top: 10, bottom: 10),
          itemCount: list.length,
          itemBuilder: (_, i) => PhraseTile(list[i], i),
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
                for (var i = 0; i < ps.length; i++) PhraseTile(ps[i], i),
              ]),
      ),
    ]);
  }
}
