import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Lightweight app localization for the driver-facing screens. Reactive via
/// [appLocale] — the app root rebuilds when it changes. Central-Asian trio
/// (ky/uz/tk) is machine-drafted (β) and wants a native proofread.
final ValueNotifier<String> appLocale = ValueNotifier<String>('en');

const List<({String code, String label, bool beta})> kLangs = [
  (code: 'en', label: 'English', beta: false),
  (code: 'es', label: 'Español', beta: false),
  (code: 'ru', label: 'Русский', beta: false),
  (code: 'tr', label: 'Türkçe', beta: false),
  (code: 'uk', label: 'Українська', beta: false),
  (code: 'pl', label: 'Polski', beta: false),
  (code: 'sr', label: 'Srpski', beta: false),
  (code: 'ky', label: 'Кыргызча', beta: true),
  (code: 'uz', label: "O'zbekcha", beta: true),
  (code: 'tk', label: 'Türkmençe', beta: true),
];

Future<void> loadLocale() async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('truxon-lang');
  if (saved != null && kLangs.any((l) => l.code == saved)) appLocale.value = saved;
}

Future<void> setLocale(String code) async {
  appLocale.value = code;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('truxon-lang', code);
}

/// Translate a key for the current locale (falls back to English, then the key).
String tr(String key) => _S[appLocale.value]?[key] ?? _S['en']![key] ?? key;

const Map<String, Map<String, String>> _S = {
  'en': {
    'companion': 'Companion', 'email': 'Email', 'password': 'Password', 'signIn': 'Sign in',
    'signingIn': 'Signing in…', 'loads': 'Loads', 'trux': 'Trux', 'radio': 'Radio', 'about': 'About',
    'sharingLocation': 'Sharing location', 'alwaysOn': 'Always on — dispatch can see the truck 24/7',
    'locationRequired': 'Location is required', 'enable': 'Enable', 'noLoads': 'No assigned loads.',
    'signOut': 'Sign out', 'language': 'Language', 'photoPod': 'Photo POD', 'paperwork': 'Paperwork',
  },
  'es': {
    'companion': 'Companion', 'email': 'Correo', 'password': 'Contraseña', 'signIn': 'Iniciar sesión',
    'signingIn': 'Iniciando…', 'loads': 'Cargas', 'trux': 'Trux', 'radio': 'Radio', 'about': 'Info',
    'sharingLocation': 'Compartiendo ubicación', 'alwaysOn': 'Siempre activo — despacho ve el camión 24/7',
    'locationRequired': 'Se requiere ubicación', 'enable': 'Activar', 'noLoads': 'Sin cargas asignadas.',
    'signOut': 'Cerrar sesión', 'language': 'Idioma', 'photoPod': 'Foto POD', 'paperwork': 'Documentos',
  },
  'ru': {
    'companion': 'Companion', 'email': 'Эл. почта', 'password': 'Пароль', 'signIn': 'Войти',
    'signingIn': 'Вход…', 'loads': 'Грузы', 'trux': 'Trux', 'radio': 'Рация', 'about': 'О программе',
    'sharingLocation': 'Передаём местоположение', 'alwaysOn': 'Всегда включено — диспетчер видит грузовик 24/7',
    'locationRequired': 'Требуется геолокация', 'enable': 'Включить', 'noLoads': 'Нет назначенных грузов.',
    'signOut': 'Выйти', 'language': 'Язык', 'photoPod': 'Фото POD', 'paperwork': 'Документы',
  },
  'tr': {
    'companion': 'Companion', 'email': 'E-posta', 'password': 'Şifre', 'signIn': 'Giriş yap',
    'signingIn': 'Giriş yapılıyor…', 'loads': 'Yükler', 'trux': 'Trux', 'radio': 'Telsiz', 'about': 'Hakkında',
    'sharingLocation': 'Konum paylaşılıyor', 'alwaysOn': 'Her zaman açık — sevkiyat kamyonu 7/24 görür',
    'locationRequired': 'Konum gerekli', 'enable': 'Etkinleştir', 'noLoads': 'Atanmış yük yok.',
    'signOut': 'Çıkış yap', 'language': 'Dil', 'photoPod': 'POD Fotoğrafı', 'paperwork': 'Evraklar',
  },
  'uk': {
    'companion': 'Companion', 'email': 'Ел. пошта', 'password': 'Пароль', 'signIn': 'Увійти',
    'signingIn': 'Вхід…', 'loads': 'Вантажі', 'trux': 'Trux', 'radio': 'Рація', 'about': 'Про застосунок',
    'sharingLocation': 'Передаємо місцезнаходження', 'alwaysOn': 'Завжди увімкнено — диспетчер бачить вантажівку 24/7',
    'locationRequired': 'Потрібне місцезнаходження', 'enable': 'Увімкнути', 'noLoads': 'Немає призначених вантажів.',
    'signOut': 'Вийти', 'language': 'Мова', 'photoPod': 'Фото POD', 'paperwork': 'Документи',
  },
  'pl': {
    'companion': 'Companion', 'email': 'E-mail', 'password': 'Hasło', 'signIn': 'Zaloguj się',
    'signingIn': 'Logowanie…', 'loads': 'Ładunki', 'trux': 'Trux', 'radio': 'Radio', 'about': 'O aplikacji',
    'sharingLocation': 'Udostępnianie lokalizacji', 'alwaysOn': 'Zawsze włączone — dyspozytor widzi ciężarówkę 24/7',
    'locationRequired': 'Wymagana lokalizacja', 'enable': 'Włącz', 'noLoads': 'Brak przypisanych ładunków.',
    'signOut': 'Wyloguj', 'language': 'Język', 'photoPod': 'Zdjęcie POD', 'paperwork': 'Dokumenty',
  },
  'sr': {
    'companion': 'Companion', 'email': 'Imejl', 'password': 'Lozinka', 'signIn': 'Prijava',
    'signingIn': 'Prijavljivanje…', 'loads': 'Tovari', 'trux': 'Trux', 'radio': 'Radio', 'about': 'O aplikaciji',
    'sharingLocation': 'Deljenje lokacije', 'alwaysOn': 'Uvek uključeno — dispečer vidi kamion 24/7',
    'locationRequired': 'Potrebna je lokacija', 'enable': 'Uključi', 'noLoads': 'Nema dodeljenih tovara.',
    'signOut': 'Odjava', 'language': 'Jezik', 'photoPod': 'POD fotografija', 'paperwork': 'Dokumenta',
  },
  'ky': {
    'companion': 'Companion', 'email': 'Эл. почта', 'password': 'Сырсөз', 'signIn': 'Кирүү',
    'signingIn': 'Кирүүдө…', 'loads': 'Жүктөр', 'trux': 'Trux', 'radio': 'Радио', 'about': 'Тууралуу',
    'sharingLocation': 'Жайгашкан жерди бөлүшүү', 'alwaysOn': 'Дайыма күйүк — диспетчер жүк ташуучуну 24/7 көрөт',
    'locationRequired': 'Жайгашкан жер керек', 'enable': 'Күйгүзүү', 'noLoads': 'Дайындалган жүк жок.',
    'signOut': 'Чыгуу', 'language': 'Тил', 'photoPod': 'POD сүрөтү', 'paperwork': 'Документтер',
  },
  'uz': {
    'companion': 'Companion', 'email': 'Email', 'password': 'Parol', 'signIn': 'Kirish',
    'signingIn': 'Kirilmoqda…', 'loads': 'Yuklar', 'trux': 'Trux', 'radio': 'Radio', 'about': 'Ilova haqida',
    'sharingLocation': 'Joylashuv ulashilmoqda', 'alwaysOn': "Doim yoniq — dispetcher yuk mashinasini 24/7 ko'radi",
    'locationRequired': 'Joylashuv talab qilinadi', 'enable': 'Yoqish', 'noLoads': 'Tayinlangan yuklar yoʻq.',
    'signOut': 'Chiqish', 'language': 'Til', 'photoPod': 'POD surati', 'paperwork': 'Hujjatlar',
  },
  'tk': {
    'companion': 'Companion', 'email': 'E-poçta', 'password': 'Parol', 'signIn': 'Girmek',
    'signingIn': 'Girilýär…', 'loads': 'Ýükler', 'trux': 'Trux', 'radio': 'Radio', 'about': 'Programma hakda',
    'sharingLocation': 'Ýerleşiş paýlaşylýar', 'alwaysOn': 'Hemişe açyk — dispetçer ýük ulagyny 24/7 görýär',
    'locationRequired': 'Ýerleşiş gerek', 'enable': 'Açmak', 'noLoads': 'Bellenen ýük ýok.',
    'signOut': 'Çykmak', 'language': 'Dil', 'photoPod': 'POD suraty', 'paperwork': 'Resminamalar',
  },
};
