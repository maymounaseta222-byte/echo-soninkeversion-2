import re

p = 'android/app/src/main/AndroidManifest.xml'
s = open(p, encoding='utf-8').read()

perms = (
    '\n    <uses-permission android:name="android.permission.INTERNET"/>'
    '\n    <uses-permission android:name="android.permission.RECORD_AUDIO"/>\n'
)
s = re.sub(r'(<manifest[^>]*>)', lambda m: m.group(1) + perms, s, count=1)

intent = '<intent><action android:name="android.speech.RecognitionService"/></intent>'
if '<queries>' in s:
    s = s.replace('<queries>', '<queries>' + intent, 1)
else:
    s = s.replace('<application', '<queries>' + intent + '</queries>\n    <application', 1)

s = s.replace('android:label="soninke_echo"', "android:label=\"Sonink'Écho\"")
open(p, 'w', encoding='utf-8').write(s)
print(s)
