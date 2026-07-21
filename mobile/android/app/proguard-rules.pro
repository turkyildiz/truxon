# google_mlkit_text_recognition references every script recognizer
# (Chinese/Devanagari/Japanese/Korean) but we only bundle the Latin model —
# a POD scan never needs the others. Those code paths are unreachable with
# our config, so silence R8's missing-class check for them.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
