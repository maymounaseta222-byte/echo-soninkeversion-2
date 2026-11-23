import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const SoninkeEchoApp());

const violet = Color(0xFF5B3CC4);

class Entry {
  final String fr, so, audioSo, audioFr, theme, phon, exSo, exFr, keywords;
  Entry(Map<String, dynamic> j)
      : fr = (j['Mots français'] ?? j['fr'] ?? '').toString().trim(),
        so = (j['Mots soninké'] ?? j['so'] ?? '').toString().trim(),
        audioSo = (j['Audio_Soninké'] ?? j['audioSo'] ?? '').toString().trim(),
        audioFr = (j['Audio_Français'] ?? j['audioFr'] ?? '').toString().trim(),
        theme = (j['Thème'] ?? j['theme'] ?? '').toString().trim(),
        phon = (j['phonetique micro'] ?? j['phon'] ?? '').toString().trim(),
        exSo = (j['Exemple soninké'] ?? '').toString().trim(),
        exFr = (j['Exemple français'] ?? '').toString().trim(),
        keywords = (j['mots clés-recherche'] ?? '').toString().trim();
  String get id => '$fr|$so';
}

class Phrase {
  final String fr, so;
  Phrase(Map<String, dynamic> j)
      : fr = (j['Mots français'] ?? j['fr'] ?? '').toString().trim(),
        so = (j['Mots soninké'] ?? j['so'] ?? '').toString().trim();
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

  Future<void> load() async {
    try {
      final raw = await rootBundle.loadString('assets/data/data.json');
      final j = jsonDecode(raw);
      List rawList = [];
      if (j is List) {
        rawList = j;
      } else if (j is Map) {
        rawList = (j['words'] ?? []) as List;
        phrases = ((j['phrases'] ?? []) as List).map((e) => Phrase(e)).toList();
      }
      words = rawList
          .map((e) => Entry(e))
          .where((w) => (w.fr.isNotEmpty && w.fr != '-') || (w.so.isNotEmpty && w.so != '-'))
          .toList();
      _p = await SharedPreferences.getInstance();
      favs = (_p!.getStringList('favs') ?? []).toSet();
    } catch (_) {}
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
    if (n.isEmpty) return words;
    return words.where((w) {
      return norm(w.fr).contains(n) ||
          norm(w.so).contains(n) ||
          norm(w.phon).contains(n) ||
          norm(w.theme).contains(n) ||
          norm(w.keywords).contains(n);
    }).toList();
  }
}

final state = AppState();

class SoninkeEchoApp extends StatelessWidget {
  const SoninkeEchoApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: "Sonink'Écho",
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: violet), useMaterial3: true),
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
  @override
  void initState() {
    super.initState();
    state.load();
    state.addListener(() => mounted ? setState(() {}) : null);
  }

  @override
  Widget build(BuildContext context) {
    final pages = [const SearchPage(), const DictPage(), const PhrasesPage(), const FavsPage()];
    return Scaffold(
      appBar: AppBar(title: const Text("Sonink'Écho")),
      body: pages[tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.search), label: 'Traduire'),
          NavigationDestination(icon: Icon(Icons.menu_book), label: 'Dictionnaire'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), label: 'Phrases'),
          NavigationDestination(icon: Icon(Icons.star_border), label: 'Favoris'),
        ],
      ),
    );
  }
}
class WordTile extends StatelessWidget {
  final Entry e;
  const WordTile(this.e, {super.key});
  @override
  Widget build(BuildContext context) {
    final fav = state.favs.contains(e.id);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.so, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                  if (e.phon.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text('[${e.phon}]', style: const TextStyle(fontStyle: FontStyle.italic, color: violet, fontSize: 14)),
                  ],
                  const SizedBox(height: 4),
                  Text(e.fr, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                  if (e.exSo.isNotEmpty || e.exFr.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.grey.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (e.exSo.isNotEmpty) Text('« ${e.exSo} »', style: const TextStyle(fontStyle: FontStyle.italic, fontSize: 13)),
                          if (e.exFr.isNotEmpty) Text(e.exFr, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                        ],
                      ),
                    ),
                  ],
                  if (e.theme.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(color: violet.withOpacity(0.1), borderRadius: BorderRadius.circular(8)),
                      child: Text(e.theme, style: const TextStyle(fontSize: 11, color: violet, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ],
              ),
            ),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (e.audioFr.isNotEmpty) IconButton(icon: const Icon(Icons.volume_up, color: Colors.blue), onPressed: () => state.play(e.audioFr)),
              if (e.audioSo.isNotEmpty) IconButton(icon: const Icon(Icons.volume_up, color: Colors.green), onPressed: () => state.play(e.audioSo)),
              IconButton(icon: Icon(fav ? Icons.star : Icons.star_border, color: Colors.amber), onPressed: () => state.toggleFav(e.id)),
            ]),
          ],
        ),
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
  final _ctrl = TextEditingController();
  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final res = state.search(q);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: TextField(
          controller: _ctrl,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            suffixIcon: q.isNotEmpty ? IconButton(icon: const Icon(Icons.clear), onPressed: () { _ctrl.clear(); setState(() => q = ''); }) : null,
            hintText: 'Filtrer parmi ${state.words.length} mots…',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          ),
          onChanged: (v) => setState(() => q = v),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(q.isEmpty ? 'Tous les mots (${res.length})' : '${res.length} résultat(s)', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
      ),
      Expanded(child: res.isEmpty ? const Center(child: Text('Aucun mot trouvé')) : ListView.builder(itemCount: res.length, itemBuilder: (_, i) => WordTile(res[i]))),
    ]);
  }
}

class DictPage extends StatefulWidget {
  const DictPage({super.key});
  @override
  State<DictPage> createState() => _DictPageState();
}

class _DictPageState extends State<DictPage> {
  bool frToSo = true;
  String? theme;
  @override
  Widget build(BuildContext context) {
    final themes = state.words.map((w) => w.theme).where((t) => t.isNotEmpty).toSet().toList()..sort();
    var list = state.words.where((w) => theme == null || w.theme == theme).toList();
    list.sort((a, b) => norm(frToSo ? a.fr : a.so).compareTo(norm(frToSo ? b.fr : b.so)));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: SegmentedButton<bool>(
          segments: const [ButtonSegment(value: true, label: Text('Français → Soninké')), ButtonSegment(value: false, label: Text('Soninké → Français'))],
          selected: {frToSo},
          onSelectionChanged: (s) => setState(() => frToSo = s.first),
        ),
      ),
      SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ChoiceChip(label: const Text('Tous'), selected: theme == null, onSelected: (_) => setState(() => theme = null))),
          for (final t in themes) Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: ChoiceChip(label: Text(t), selected: theme == t, onSelected: (_) => setState(() => theme = t))),
        ]),
      ),
      Expanded(child: ListView.builder(itemCount: list.length, itemBuilder: (_, i) => WordTile(list[i]))),
    ]);
  }
}

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
    final list = state.phrases.where((p) => n.isEmpty || norm(p.fr).contains(n) || norm(p.so).contains(n)).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: 'Rechercher une phrase…', border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
          onChanged: (v) => setState(() => q = v),
        ),
      ),
      Expanded(
        child: ListView.builder(
          itemCount: list.length,
          itemBuilder: (_, i) {
            final p = list[i];
            final fav = state.favs.contains(p.id);
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                title: Text(p.fr),
                subtitle: Text(p.so, style: const TextStyle(fontWeight: FontWeight.bold, color: violet)),
                trailing: IconButton(icon: Icon(fav ? Icons.star : Icons.star_border, color: Colors.amber), onPressed: () => state.toggleFav(p.id)),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class FavsPage extends StatelessWidget {
  const FavsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final ws = state.words.where((w) => state.favs.contains(w.id)).toList();
    final ps = state.phrases.where((p) => state.favs.contains(p.id)).toList();
    if (ws.isEmpty && ps.isEmpty) return const Center(child: Text("Aucun favori pour l'instant ⭐"));
    return ListView(children: [
      for (final w in ws) WordTile(w),
      for (final p in ps) Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ListTile(
          title: Text(p.fr),
          subtitle: Text(p.so, style: const TextStyle(fontWeight: FontWeight.bold, color: violet)),
          trailing: IconButton(icon: const Icon(Icons.star, color: Colors.amber), onPressed: () => state.toggleFav(p.id)),
        ),
      ),
    ]);
  }
}
