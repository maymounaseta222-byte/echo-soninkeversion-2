import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const SoninkeEchoApp());

const violet = Color(0xFF5B3CC4);

class Entry {
  final String fr, so, audioSo, audioFr, theme, phon;
  Entry(Map<String, dynamic> j)
      : fr = j['fr'] ?? '',
        so = j['so'] ?? '',
        audioSo = j['audioSo'] ?? '',
        audioFr = j['audioFr'] ?? '',
        theme = j['theme'] ?? '',
        phon = j['phon'] ?? '';
  String get id => '$fr|$so';
}

class Phrase {
  final String fr, so;
  Phrase(Map<String, dynamic> j)
      : fr = j['fr'] ?? '',
        so = j['so'] ?? '';
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
    final raw = await rootBundle.loadString('assets/data/data.json');
    final j = jsonDecode(raw);
    words = (j['words'] as List).map((e) => Entry(e)).toList();
    phrases = (j['phrases'] as List).map((e) => Phrase(e)).toList();
    _p = await SharedPreferences.getInstance();
    favs = (_p!.getStringList('favs') ?? []).toSet();
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
    // MODIFICATION : Si la recherche est vide, on affiche tous les mots au lieu d'une liste vide
    if (n.isEmpty) return words;
    return words.where((w) {
      return norm(w.fr).contains(n) ||
          norm(w.so).contains(n) ||
          norm(w.phon).contains(n) ||
          norm(w.theme).contains(n);
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
        theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: violet), useMaterial3: true),
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
    final pages = [
      const SearchPage(),
      const DictPage(),
      const PhrasesPage(),
      const FavsPage(),
    ];
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
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.so,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  if (e.phon.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      '[${e.phon}]',
                      style: const TextStyle(
                        fontStyle: FontStyle.italic,
                        color: violet,
                        fontSize: 14,
                      ),
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    e.fr,
                    style: const TextStyle(fontSize: 15),
                  ),
                  if (e.theme.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: violet.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        e.theme,
                        style: const TextStyle(
                          fontSize: 11,
                          color: violet,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (e.audioFr.isNotEmpty)
                IconButton(
                    tooltip: 'Écouter en français',
                    icon: const Icon(Icons.volume_up, color: Colors.blue),
                    onPressed: () => state.play(e.audioFr)),
              if (e.audioSo.isNotEmpty)
                IconButton(
                    tooltip: 'Écouter en soninké',
                    icon: const Icon(Icons.volume_up, color: Colors.green),
                    onPressed: () => state.play(e.audioSo)),
              IconButton(
                  icon: Icon(fav ? Icons.star : Icons.star_border, color: Colors.amber),
                  onPressed: () => state.toggleFav(e.id)),
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
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

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
            suffixIcon: q.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _ctrl.clear();
                      setState(() => q = '');
                    },
                  )
                : null,
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
          child: Text(
            q.isEmpty
                ? 'Tous les mots (${res.length}) • ${state.phrases.length} phrases'
                : '${res.length} résultat(s) trouvé(s)',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      Expanded(
        child: res.isEmpty
            ? const Center(child: Text('Aucun mot trouvé'))
            : ListView.builder(
                itemCount: res.length,
                itemBuilder: (_, i) => WordTile(res[i]),
              ),
      ),
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
          segments: const [
            ButtonSegment(value: true, label: Text('Français → Soninké')),
            ButtonSegment(value: false, label: Text('Soninké → Français')),
          ],
          selected: {frToSo},
          onSelectionChanged: (s) => setState(() => frToSo = s.first),
        ),
      ),
      SizedBox(
        height: 48,
        child: ListView(scrollDirection: Axis.horizontal, children: [
          Padding(
