# Sonink'Écho (Flutter) - version 1

## Installation (Windows)
1. Installer Flutter : https://docs.flutter.dev/get-started/install/windows
2. Installer Android Studio (SDK Android + émulateur)
3. Dans ce dossier, ouvrir un terminal :
   flutter create .      (génère les dossiers android/ ios/ sans toucher à lib/ ni pubspec.yaml)
   flutter pub get
   flutter run
4. Pour le Play Store : flutter build appbundle

## Android : autoriser internet (audios)
Dans android/app/src/main/AndroidManifest.xml, avant <application> :
   <uses-permission android:name="android.permission.INTERNET"/>

## Mettre à jour les données
assets/data/data.json (417 mots, 92 phrases) est généré depuis tes CSV.
Les e-mails et IDs Softr ont été retirés.
