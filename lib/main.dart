import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'ggGame.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, HttpHeaders, HttpClient;
import 'dart:math' as _math;

import 'package:appsflyer_sdk/appsflyer_sdk.dart' as af_core;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodChannel, SystemChrome, SystemUiOverlayStyle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz_zone;

import 'jacks.dart';


Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(blackjackFcmBg);

  if (Platform.isAndroid) {
    await InAppWebViewController.setWebContentsDebuggingEnabled(true);
  }
  tz_data.initializeTimeZones();

//  runApp(UnityWebGLApp(server: server));
  runApp(
    const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: BlackjackLobby(),
    ),
  );
}


Future<UnityAssetServer> _startUnityServer({required int port}) async {
  final manifestJson = await rootBundle.loadString('AssetManifest.json');
  final manifest = Map<String, dynamic>.from(json.decode(manifestJson));
  final availableAssets = manifest.keys.toSet();

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  debugPrint('Unity asset server listening on http://localhost:$port');

  server.listen((HttpRequest request) async {
    final originalPath =
    request.uri.path == '/' ? '/unity/index.html' : request.uri.path;
    final decodedPath = Uri.decodeComponent(originalPath);

    final assetCandidates = <String>[
      'assets$decodedPath',
      if (decodedPath.endsWith('.data'))
        'assets${decodedPath}.unityweb',
      if (decodedPath.endsWith('.wasm'))
        'assets${decodedPath}.unityweb',
      if (decodedPath.endsWith('.js'))
        'assets${decodedPath}.unityweb',
    ];

    ByteData? byteData;
    String? hitPath;

    for (final candidate in assetCandidates) {
      if (availableAssets.contains(candidate)) {
        hitPath = candidate;
        byteData = await rootBundle.load(candidate);
        break;
      }
    }

    if (byteData == null) {
      debugPrint('404 -> $decodedPath (candidates: $assetCandidates)');
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('Not found: $decodedPath');
      await request.response.close();
      return;
    }

    final headers = request.response.headers;
    headers.set(HttpHeaders.cacheControlHeader, 'public, max-age=31536000');

    void addEncoding(String encoding) {
      headers.add(HttpHeaders.contentEncodingHeader, encoding);
    }

    if (hitPath!.endsWith('.html')) {
      headers.contentType = ContentType.html;
    } else if (hitPath.endsWith('.js') || hitPath.endsWith('.js.unityweb')) {
      headers.contentType =
          ContentType('application', 'javascript', charset: 'utf-8');
    } else if (hitPath.endsWith('.css')) {
      headers.contentType = ContentType('text', 'css', charset: 'utf-8');
    } else if (hitPath.endsWith('.wasm') || hitPath.endsWith('.wasm.unityweb')) {
      headers.contentType = ContentType('application', 'wasm');
    } else if (hitPath.endsWith('.data') || hitPath.endsWith('.data.unityweb')) {
      headers.contentType = ContentType('application', 'octet-stream');
    } else {
      headers.contentType = ContentType.binary;
    }

    if (hitPath.endsWith('.unityweb')) {
      addEncoding('gzip'); // или 'br', если билд в Brotli
    }

    debugPrint('200 <- $decodedPath (served: $hitPath)');
    request.response.add(byteData.buffer.asUint8List());
    await request.response.close();
  });

  return UnityAssetServer(server);
}

class UnityAssetServer {
  UnityAssetServer(this._server);
  final HttpServer _server;
  int get port => _server.port;

  Future<void> stop() async => _server.close(force: true);
}



// ============================================================================
// Константы
// ============================================================================
const String kBlackjackLoadedOnceKey = 'blackjack_loaded_once';
const String kBlackjackStatEndpoint = 'https://jrekfne.blackjacktime.monster/stat';
const String kBlackjackCachedFcmKey = 'blackjack_cached_fcm';

// ============================================================================
// Лёгкие сервисы
// ============================================================================
class BlackjackShoe {
  static final BlackjackShoe _shoe = BlackjackShoe._();
  BlackjackShoe._();
  factory BlackjackShoe() => _shoe;

  final Connectivity neonNetwork = Connectivity();

  void logInfoCard(Object msg) => debugPrint('[I] $msg');
  void logWarnCard(Object msg) => debugPrint('[W] $msg');
  void logErrorCard(Object msg) => debugPrint('[E] $msg');
}

// ============================================================================
// Сеть/данные: BlackjackSignalWire
// ============================================================================
class BlackjackSignalWire {
  final BlackjackShoe _shoe = BlackjackShoe();

  Future<bool> checkTableOnline() async {
    final status = await _shoe.neonNetwork.checkConnectivity();
    return status != ConnectivityResult.none;
  }

  Future<void> pushJsonToPit(String url, Map<String, dynamic> data) async {
    try {
      await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(data),
      );
    } catch (e) {
      _shoe.logErrorCard('pushJsonToPit error: $e');
    }
  }
}

// ============================================================================
// Досье устройства: BlackjackDeviceCard
// ============================================================================
class BlackjackDeviceCard {
  String? gamblerDeviceId;
  String? sessionMarker = 'blackjack-one-off';
  String? platformTag;
  String? osLabel;
  String? appBuild;
  String? localeCode;
  String? timezoneLabel;
  bool pushAllowed = true;

  Future<void> primeDeviceCard() async {
    final infoPlugin = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final android = await infoPlugin.androidInfo;
      gamblerDeviceId = android.id;
      platformTag = 'android';
      osLabel = android.version.release;
    } else if (Platform.isIOS) {
      final ios = await infoPlugin.iosInfo;
      gamblerDeviceId = ios.identifierForVendor;
      platformTag = 'ios';
      osLabel = ios.systemVersion;
    }
    final pkg = await PackageInfo.fromPlatform();
    appBuild = pkg.version;
    localeCode = Platform.localeName.split('_').first;
    timezoneLabel = tz_zone.local.name;
    sessionMarker = 'blackjack-${DateTime.now().millisecondsSinceEpoch}';
  }

  Map<String, dynamic> toHandMap({String? fcm}) => {
    'fcm_token': fcm ?? 'missing_token',
    'device_id': gamblerDeviceId ?? 'missing_id',
    'app_name': 'blackjacktime',
    'instance_id': sessionMarker ?? 'missing_session',
    'platform': platformTag ?? 'missing_system',
    'os_version': osLabel ?? 'missing_build',
    'app_version': appBuild ?? 'missing_app',
    'language': localeCode ?? 'en',
    'timezone': timezoneLabel ?? 'UTC',
    'push_enabled': pushAllowed,
  };
}

// ============================================================================
// AppsFlyer: BlackjackPitBoss
// ============================================================================
class BlackjackPitBoss {
  af_core.AppsFlyerOptions? _pitOptions;
  af_core.AppsflyerSdk? _pitSdk;

  String pitBossUid = '';
  String pitBossData = '';

  void startPit({VoidCallback? onUpdate}) {
    final cfg = af_core.AppsFlyerOptions(
      afDevKey: 'qsBLmy7dAXDQhowM8V3ca4',
      appId: '6755542932',
      showDebug: true,
      timeToWaitForATTUserAuthorization: 0,
    );
    _pitOptions = cfg;
    _pitSdk = af_core.AppsflyerSdk(cfg);

    _pitSdk?.initSdk(
      registerConversionDataCallback: true,
      registerOnAppOpenAttributionCallback: true,
      registerOnDeepLinkingCallback: true,
    );
    _pitSdk?.startSDK(
      onSuccess: () => BlackjackShoe().logInfoCard('BlackjackPitBoss started'),
      onError: (code, msg) => BlackjackShoe().logErrorCard('BlackjackPitBoss error $code: $msg'),
    );

    _pitSdk?.onInstallConversionData((data) {
      pitBossData = data.toString();
      onUpdate?.call();
    });

    _pitSdk?.getAppsFlyerUID().then((value) {
      pitBossUid = value.toString();
      onUpdate?.call();
    });
  }
}

// ============================================================================
// Новый лоадер с песочными часами
// ============================================================================
class BlackjackHourglassLoader extends StatefulWidget {
  const BlackjackHourglassLoader({Key? key}) : super(key: key);

  @override
  State<BlackjackHourglassLoader> createState() => _BlackjackHourglassLoaderState();
}

class _BlackjackHourglassLoaderState extends State<BlackjackHourglassLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flipController;

  @override
  void initState() {
    super.initState();
    _flipController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _flipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _flipController,
      builder: (_, __) {
        final progress = _flipController.value;
        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'JACK LAIR',
                style: TextStyle(
                  fontSize: 36,
                  letterSpacing: 6,
                  fontWeight: FontWeight.bold,
                  color: const Color(0xFF00FFC6),
                  shadows: [
                    Shadow(
                      color: const Color(0xFF00FFC6).withOpacity(0.8),
                      blurRadius: 18,
                    ),
                    Shadow(
                      color: Colors.pinkAccent.withOpacity(0.6),
                      blurRadius: 28,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 36),
              SizedBox(
                width: 160,
                height: 220,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    const _BlackjackNeonAura(),
                    Transform.rotate(
                      angle: progress * _math.pi,
                      child: CustomPaint(
                        painter: BlackjackHourglassPainter(sandProgress: progress),
                        size: const Size(140, 200),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _BlackjackNeonAura extends StatelessWidget {
  const _BlackjackNeonAura();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      height: 220,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00FFC6).withOpacity(0.4),
            blurRadius: 48,
            spreadRadius: 12,
          ),
          BoxShadow(
            color: Colors.purpleAccent.withOpacity(0.25),
            blurRadius: 70,
            spreadRadius: 20,
          ),
        ],
      ),
    );
  }
}

class BlackjackHourglassPainter extends CustomPainter {
  final double sandProgress;
  const BlackjackHourglassPainter({required this.sandProgress});

  @override
  void paint(Canvas canvas, Size size) {
    final frameColor = const Color(0xFF00FFC6);
    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = frameColor.withOpacity(0.35)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 30);
    final framePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white.withOpacity(0.85);

    final topY = size.height * 0.08;
    final bottomY = size.height * 0.92;
    final centerY = size.height * 0.5;
    final leftX = size.width * 0.18;
    final rightX = size.width * 0.82;

    final path = Path()
      ..moveTo(leftX, topY)
      ..lineTo(rightX, topY)
      ..lineTo(size.width * 0.5, centerY)
      ..lineTo(rightX, bottomY)
      ..lineTo(leftX, bottomY)
      ..lineTo(size.width * 0.5, centerY)
      ..close();

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, framePaint);

    final topPath = Path()
      ..moveTo(leftX, topY)
      ..lineTo(rightX, topY)
      ..lineTo(size.width * 0.5, centerY)
      ..close();
    final bottomPath = Path()
      ..moveTo(leftX, bottomY)
      ..lineTo(rightX, bottomY)
      ..lineTo(size.width * 0.5, centerY)
      ..close();

    final topSandPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        colors: [Colors.amberAccent, Colors.orangeAccent.withOpacity(0.4)],
      ).createShader(Rect.fromLTWH(leftX, topY, rightX - leftX, centerY - topY));

    final bottomSandPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        colors: [Colors.deepOrangeAccent.withOpacity(0.6), Colors.amber],
      ).createShader(Rect.fromLTWH(leftX, centerY, rightX - leftX, bottomY - centerY));

    final topLevel = (1 - sandProgress).clamp(0.0, 1.0);
    final bottomLevel = sandProgress.clamp(0.0, 1.0);

    canvas.save();
    canvas.clipPath(topPath);
    canvas.drawRect(
      Rect.fromLTRB(
        leftX,
        topY + (centerY - topY) * (1 - topLevel),
        rightX,
        centerY,
      ),
      topSandPaint,
    );
    canvas.restore();

    canvas.save();
    canvas.clipPath(bottomPath);
    canvas.drawRect(
      Rect.fromLTRB(
        leftX,
        centerY,
        rightX,
        centerY + (bottomY - centerY) * bottomLevel,
      ),
      bottomSandPaint,
    );
    canvas.restore();

    final streamPaint = Paint()
      ..style = PaintingStyle.fill
      ..shader = LinearGradient(
        colors: [Colors.amberAccent, Colors.white.withOpacity(0.8)],
      ).createShader(Rect.fromCircle(center: Offset(size.width * 0.5, centerY), radius: 6));

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(size.width * 0.5, centerY),
          width: 4,
          height: (centerY - topY) * 0.6,
        ),
        const Radius.circular(4),
      ),
      streamPaint,
    );
  }

  @override
  bool shouldRepaint(covariant BlackjackHourglassPainter oldDelegate) =>
      oldDelegate.sandProgress != sandProgress;
}

// ============================================================================
// FCM фоновые крики
// ============================================================================
@pragma('vm:entry-point')
Future<void> blackjackFcmBg(RemoteMessage msg) async {
  BlackjackShoe().logInfoCard('bg-fcm: ${msg.messageId}');
  BlackjackShoe().logInfoCard('bg-data: ${msg.data}');
}

// ============================================================================
// Мост для получения токена: BlackjackFcmBridge
// ============================================================================
class BlackjackFcmBridge {
  final BlackjackShoe _shoe = BlackjackShoe();
  String? _tokenChip;
  final List<void Function(String)> _waiters = [];

  String? get tokenChip => _tokenChip;

  BlackjackFcmBridge() {
    const MethodChannel('com.example.fcm/token').setMethodCallHandler((call) async {
      if (call.method == 'setToken') {
        final String incoming = call.arguments as String;
        if (incoming.isNotEmpty) {
          _setTokenChip(incoming);
        }
      }
    });
    _restoreCachedChip();
  }

  Future<void> _restoreCachedChip() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(kBlackjackCachedFcmKey);
      if (cached != null && cached.isNotEmpty) {
        _setTokenChip(cached, notify: false);
      }
    } catch (_) {}
  }

  Future<void> _cacheTokenChip(String token) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kBlackjackCachedFcmKey, token);
    } catch (_) {}
  }

  void _setTokenChip(String token, {bool notify = true}) {
    _tokenChip = token;
    _cacheTokenChip(token);
    if (notify) {
      for (final cb in List.of(_waiters)) {
        try {
          cb(token);
        } catch (e) {
          _shoe.logWarnCard('fcm waiter error: $e');
        }
      }
      _waiters.clear();
    }
  }

  Future<void> waitForTokenChip(Function(String token) onToken) async {
    try {
      await FirebaseMessaging.instance.requestPermission(alert: true, badge: true, sound: true);
      if ((_tokenChip ?? '').isNotEmpty) {
        onToken(_tokenChip!);
        return;
      }
      _waiters.add(onToken);
    } catch (e) {
      _shoe.logErrorCard('waitForTokenChip error: $e');
    }
  }
}

// ============================================================================
// Лобби: BlackjackLobby
// ============================================================================
class BlackjackLobby extends StatefulWidget {
  const BlackjackLobby({Key? key}) : super(key: key);

  @override
  State<BlackjackLobby> createState() => _BlackjackLobbyState();
}

class _BlackjackLobbyState extends State<BlackjackLobby> {
  final BlackjackFcmBridge _dealerBridge = BlackjackFcmBridge();
  bool _hasShuffled = false;
  Timer? _failSafeTimer;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.black,
      statusBarIconBrightness: Brightness.light,
      statusBarBrightness: Brightness.dark,
    ));

    _dealerBridge.waitForTokenChip((token) => _dealSeat(token));
    _failSafeTimer = Timer(const Duration(seconds: 8), () => _dealSeat(''));
  }

  void _dealSeat(String signature) {
    if (_hasShuffled) return;
    _hasShuffled = true;
    _failSafeTimer?.cancel();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => BlackjackTable(signalChip: signature)),
    );
  }

  @override
  void dispose() {
    _failSafeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: BlackjackHourglassLoader()),
    );
  }
}

// ============================================================================
// ViewModel + Courier
// ============================================================================
class BlackjackManifest {
  final BlackjackDeviceCard deviceCard;
  final BlackjackPitBoss pitBoss;

  BlackjackManifest({required this.deviceCard, required this.pitBoss});

  Map<String, dynamic> deviceMap(String? token) => deviceCard.toHandMap(fcm: token);

  Map<String, dynamic> pitBossMap(String? token) => {
    'content': {
      'af_data': pitBoss.pitBossData,
      'af_id': pitBoss.pitBossUid,
      'fb_app_name': 'blackjacktime',
      'app_name': 'blackjacktime',
      'deep': null,
      'bundle_identifier': 'ccom.porttoul.fag.sloungeportalroullete',
      'app_version': '1.0.0',
      'apple_id': '6755542932',
      'fcm_token': token ?? 'no_token',
      'device_id': deviceCard.gamblerDeviceId ?? 'no_device',
      'instance_id': deviceCard.sessionMarker ?? 'no_instance',
      'platform': deviceCard.platformTag ?? 'no_type',
      'os_version': deviceCard.osLabel ?? 'no_os',
      'app_version': deviceCard.appBuild ?? 'no_app',
      'language': deviceCard.localeCode ?? 'en',
      'timezone': deviceCard.timezoneLabel ?? 'UTC',
      'push_enabled': deviceCard.pushAllowed,
      'useruid': pitBoss.pitBossUid,
    },
  };
}

class BlackjackCourier {
  final BlackjackManifest manifest;
  final InAppWebViewController Function() getWeb;

  BlackjackCourier({required this.manifest, required this.getWeb});

  Future<void> stashDeviceInShoe(String? token) async {
    final map = manifest.deviceMap(token);
    await getWeb().evaluateJavascript(source: '''
localStorage.setItem('app_data', JSON.stringify(${jsonEncode(map)}));
''');
  }

  Future<void> dealRawToPage(String? token) async {
    final payload = manifest.pitBossMap(token);
    final jsonString = jsonEncode(payload);

    debugPrint('load stry$jsonString');
    BlackjackShoe().logInfoCard('SendRawData: $jsonString');
    await getWeb().evaluateJavascript(source: 'sendRawData(${jsonEncode(jsonString)});');
  }
}

// ============================================================================
// Переходы/статистика
// ============================================================================
Future<String> blackjackFinalUrl(String startUrl, {int maxHops = 10}) async {
  final client = HttpClient();

  try {
    var current = Uri.parse(startUrl);
    for (int i = 0; i < maxHops; i++) {
      final req = await client.getUrl(current);
      req.followRedirects = false;
      final res = await req.close();
      if (res.isRedirect) {
        final loc = res.headers.value(HttpHeaders.locationHeader);
        if (loc == null || loc.isEmpty) break;
        final next = Uri.parse(loc);
        current = next.hasScheme ? next : current.resolveUri(next);
        continue;
      }
      return current.toString();
    }
    return current.toString();
  } catch (e) {
    debugPrint('blackjackFinalUrl error: $e');
    return startUrl;
  } finally {
    client.close(force: true);
  }
}

Future<void> blackjackPostStat({
  required String event,
  required int timeStart,
  required String url,
  required int timeFinish,
  required String appSid,
  int? firstPageLoadTs,
}) async {
  try {
    final finalUrl = await blackjackFinalUrl(url);
    final payload = {
      'event': event,
      'timestart': timeStart,
      'timefinsh': timeFinish,
      'url': finalUrl,
      'appleID': '6755542932',
      'open_count': '$appSid/$timeStart',
    };

    debugPrint('blackjackStat $payload');
    final res = await http.post(
      Uri.parse('$kBlackjackStatEndpoint/$appSid'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    debugPrint('blackjackStat resp=${res.statusCode} body=${res.body}');
  } catch (e) {
    debugPrint('blackjackPostStat error: $e');
  }
}

// ============================================================================
// Главный WebView — BlackjackTable
// ============================================================================
class BlackjackTable extends StatefulWidget {
  final String? signalChip;
  const BlackjackTable({super.key, required this.signalChip});

  @override
  State<BlackjackTable> createState() => _BlackjackTableState();
}

class _BlackjackTableState extends State<BlackjackTable> with WidgetsBindingObserver {
  late InAppWebViewController _dealerWeb;
  final String _homeSeat = 'https://jrekfne.blackjacktime.monster/';

  int _shoeHatch = 0;
  DateTime? _sleepMoment;
  bool _veilRaised = false;
  double _warmupProgress = 0.0;
  late Timer _warmupTimer;
  final int _warmSeconds = 6;
  bool _coverActive = true;

  bool _firstDealSent = false;
  int? _firstPageTimestamp;

  BlackjackCourier? _tableCourier;
  BlackjackManifest? _tableManifest;

  String _currentHandUrl = '';
  var _loadStartStamp = 0;

  final BlackjackDeviceCard _deviceCard = BlackjackDeviceCard();
  final BlackjackPitBoss _pitBoss = BlackjackPitBoss();

  final Set<String> _platformSchemes = {
    'tg',
    'telegram',
    'whatsapp',
    'viber',
    'skype',
    'fb-messenger',
    'sgnl',
    'tel',
    'mailto',
    'bnl',
  };

  final Set<String> _platformHosts = {
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'm.me',
    'signal.me',
    'bnl.com',
    'www.bnl.com',
    'facebook.com',
    'www.facebook.com',
    'm.facebook.com',
    'instagram.com',
    'www.instagram.com',
    'twitter.com',
    'www.twitter.com',
    'x.com',
    'www.x.com',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _firstPageTimestamp = DateTime.now().millisecondsSinceEpoch;

    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _coverActive = false);
    });

    Future.delayed(const Duration(seconds: 7), () {
      if (!mounted) return;
      setState(() => _veilRaised = true);
    });

    _openPit();
  }

  Future<void> _loadFirstDealFlag() async {
    final prefs = await SharedPreferences.getInstance();
    _firstDealSent = prefs.getBool(kBlackjackLoadedOnceKey) ?? false;
  }

  Future<void> _saveFirstDealFlag() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBlackjackLoadedOnceKey, true);
    _firstDealSent = true;
  }

  Future<void> reportFirstShuffle({required String url, required int timestart}) async {
    if (_firstDealSent) {
      debugPrint('Loaded already sent, skip');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    await blackjackPostStat(
      event: 'Loaded',
      timeStart: timestart,
      timeFinish: now,
      url: url,
      appSid: _pitBoss.pitBossUid,
      firstPageLoadTs: _firstPageTimestamp,
    );
    await _saveFirstDealFlag();
  }

  void _openPit() {
    _warmUpTable();
    _wireSignals();
    _pitBoss.startPit(onUpdate: () => setState(() {}));
    _bindDealerTap();
    _prepCard();

    Future.delayed(const Duration(seconds: 6), () async {
      await _pushHandToTable();
      await _pushPitBossData();
    });
  }

  void _wireSignals() {
    FirebaseMessaging.onMessage.listen((msg) {
      final link = msg.data['uri'];
      if (link != null) {
        _swingToLane(link.toString());
      } else {
        _returnToLobby();
      }
    });
    FirebaseMessaging.onMessageOpenedApp.listen((msg) {
      final link = msg.data['uri'];
      if (link != null) {
        _swingToLane(link.toString());
      } else {
        _returnToLobby();
      }
    });
  }

  void _bindDealerTap() {
    MethodChannel('com.example.fcm/notification').setMethodCallHandler((call) async {
      if (call.method == 'onNotificationTap') {
        final Map<String, dynamic> payload = Map<String, dynamic>.from(call.arguments);
        if (payload['uri'] != null && !payload['uri'].toString().contains('Нет URI')) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => JackRouletteTableView (payload['uri'].toString())),
                (route) => false,
          );
        }
      }
    });
  }

  Future<void> _prepCard() async {
    try {
      await _deviceCard.primeDeviceCard();
      await _askPushChips();
      _tableManifest = BlackjackManifest(deviceCard: _deviceCard, pitBoss: _pitBoss);
      _tableCourier = BlackjackCourier(manifest: _tableManifest!, getWeb: () => _dealerWeb);
      await _loadFirstDealFlag();
    } catch (e) {
      BlackjackShoe().logErrorCard('prepare fail: $e');
    }
  }

  Future<void> _askPushChips() async {
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
  }

  void _swingToLane(String link) async {
    try {
      await _dealerWeb.loadUrl(urlRequest: URLRequest(url: WebUri(link)));
    } catch (e) {
      BlackjackShoe().logErrorCard('navigate error: $e');
    }
  }

  void _returnToLobby() async {
    Future.delayed(const Duration(seconds: 3), () {
      try {
        _dealerWeb.loadUrl(urlRequest: URLRequest(url: WebUri(_homeSeat)));
      } catch (_) {}
    });
  }

  Future<void> _pushHandToTable() async {
    BlackjackShoe().logInfoCard('TOKEN ship ${widget.signalChip}');
    try {
      await _tableCourier?.stashDeviceInShoe(widget.signalChip);
    } catch (e) {
      BlackjackShoe().logErrorCard('pushDevice error: $e');
    }
  }

  Future<void> _pushPitBossData() async {
    try {
      await _tableCourier?.dealRawToPage(widget.signalChip);
    } catch (e) {
      BlackjackShoe().logErrorCard('pushAf error: $e');
    }
  }

  void _warmUpTable() {
    int ticks = 0;
    _warmupProgress = 0.0;
    _warmupTimer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      if (!mounted) return;
      setState(() {
        ticks++;
        _warmupProgress = ticks / (_warmSeconds * 10);
        if (_warmupProgress >= 1.0) {
          _warmupProgress = 1.0;
          _warmupTimer.cancel();
        }
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _sleepMoment = DateTime.now();
    }
    if (state == AppLifecycleState.resumed) {
      if (Platform.isIOS && _sleepMoment != null) {
        final now = DateTime.now();
        final drift = now.difference(_sleepMoment!);
        if (drift > const Duration(minutes: 25)) {
          _resetTable();
        }
      }
      _sleepMoment = null;
    }
  }

  void _resetTable() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (context) => BlackjackTable(signalChip: widget.signalChip)),
            (route) => false,
      );
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _warmupTimer.cancel();
    super.dispose();
  }

  bool _looksLikeBareEmail(Uri uri) {
    final scheme = uri.scheme;
    if (scheme.isNotEmpty) return false;
    final raw = uri.toString();
    return raw.contains('@') && !raw.contains(' ');
  }

  Uri _convertToMailto(Uri uri) {
    final full = uri.toString();
    final parts = full.split('?');
    final email = parts.first;
    final qp = parts.length > 1 ? Uri.splitQueryString(parts[1]) : <String, String>{};
    return Uri(scheme: 'mailto', path: email, queryParameters: qp.isEmpty ? null : qp);
  }

  bool _isPlatformLane(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if (_platformSchemes.contains(scheme)) return true;

    if (scheme == 'http' || scheme == 'https') {
      final host = uri.host.toLowerCase();
      if (_platformHosts.contains(host)) return true;
      if (host.endsWith('t.me')) return true;
      if (host.endsWith('wa.me')) return true;
      if (host.endsWith('m.me')) return true;
      if (host.endsWith('signal.me')) return true;
      if (host.endsWith('facebook.com')) return true;
      if (host.endsWith('instagram.com')) return true;
      if (host.endsWith('twitter.com')) return true;
      if (host.endsWith('x.com')) return true;
    }
    return false;
  }

  String _stripDigits(String input) => input.replaceAll(RegExp(r'[^0-9+]'), '');

  Uri _normalizePlatformUri(Uri uri) {
    final scheme = uri.scheme.toLowerCase();

    if (scheme == 'tg' || scheme == 'telegram') {
      final qp = uri.queryParameters;
      final domain = qp['domain'];
      if (domain != null && domain.isNotEmpty) {
        return Uri.https('t.me', '/$domain', {if (qp['start'] != null) 'start': qp['start']!});
      }
      final path = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https('t.me', '/$path', uri.queryParameters.isEmpty ? null : uri.queryParameters);
    }

    if ((scheme == 'http' || scheme == 'https') && uri.host.toLowerCase().endsWith('t.me')) {
      return uri;
    }

    if (scheme == 'viber') return uri;

    if (scheme == 'whatsapp') {
      final qp = uri.queryParameters;
      final phone = qp['phone'];
      final text = qp['text'];
      if (phone != null && phone.isNotEmpty) {
        return Uri.https('wa.me', '/${_stripDigits(phone)}', {if (text != null && text.isNotEmpty) 'text': text});
      }
      return Uri.https('wa.me', '/', {if (text != null && text.isNotEmpty) 'text': text});
    }

    if ((scheme == 'http' || scheme == 'https') &&
        (uri.host.toLowerCase().endsWith('wa.me') || uri.host.toLowerCase().endsWith('whatsapp.com'))) {
      return uri;
    }

    if (scheme == 'skype') return uri;

    if (scheme == 'fb-messenger') {
      final path = uri.pathSegments.isNotEmpty ? uri.pathSegments.join('/') : '';
      final qp = uri.queryParameters;
      final id = qp['id'] ?? qp['user'] ?? path;
      if (id.isNotEmpty) {
        return Uri.https('m.me', '/$id', uri.queryParameters.isEmpty ? null : uri.queryParameters);
      }
      return Uri.https('m.me', '/', uri.queryParameters.isEmpty ? null : uri.queryParameters);
    }

    if (scheme == 'sgnl') {
      final qp = uri.queryParameters;
      final phone = qp['phone'];
      final username = uri.queryParameters['username'];
      if (phone != null && phone.isNotEmpty) return Uri.https('signal.me', '/#p/${_stripDigits(phone)}');
      if (username != null && username.isNotEmpty) return Uri.https('signal.me', '/#u/$username');
      final path = uri.pathSegments.join('/');
      if (path.isNotEmpty) return Uri.https('signal.me', '/$path', uri.queryParameters.isEmpty ? null : uri.queryParameters);
      return uri;
    }

    if (scheme == 'tel') {
      return Uri.parse('tel:${_stripDigits(uri.path)}');
    }

    if (scheme == 'mailto') return uri;

    if (scheme == 'bnl') {
      final newPath = uri.path.isNotEmpty ? uri.path : '';
      return Uri.https('bnl.com', '/$newPath', uri.queryParameters.isEmpty ? null : uri.queryParameters);
    }

    return uri;
  }

  Future<bool> _openMailClient(Uri mailto) async {
    final gmail = _buildGmailUri(mailto);
    return await _openInWeb(gmail);
  }

  Uri _buildGmailUri(Uri uri) {
    final qp = uri.queryParameters;
    final params = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (uri.path.isNotEmpty) 'to': uri.path,
      if ((qp['subject'] ?? '').isNotEmpty) 'su': qp['subject']!,
      if ((qp['body'] ?? '').isNotEmpty) 'body': qp['body']!,
      if ((qp['cc'] ?? '').isNotEmpty) 'cc': qp['cc']!,
      if ((qp['bcc'] ?? '').isNotEmpty) 'bcc': qp['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', params);
  }

  Future<bool> _openInWeb(Uri uri) async {
    try {
      if (await launchUrl(uri, mode: LaunchMode.inAppBrowserView)) return true;
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('openInAppBrowser error: $e; url=$uri');
      try {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
  }

  Future<bool> _openExternalApp(Uri uri) async {
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('openExternal error: $e; url=$uri');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    _bindDealerTap();

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            if (_coverActive)
              const BlackjackHourglassLoader()
            else
              Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    InAppWebView(
                      key: ValueKey(_shoeHatch),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        disableDefaultErrorPage: true,
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        allowsPictureInPictureMediaPlayback: true,
                        useOnDownloadStart: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                        useShouldOverrideUrlLoading: true,
                        supportMultipleWindows: true,
                        transparentBackground: true,
                      ),
                      initialUrlRequest: URLRequest(url: WebUri(_homeSeat)),
                      onWebViewCreated: (controller) {
                        _dealerWeb = controller;

                        _tableManifest ??= BlackjackManifest(deviceCard: _deviceCard, pitBoss: _pitBoss);
                        _tableCourier ??= BlackjackCourier(manifest: _tableManifest!, getWeb: () => _dealerWeb);

                        _dealerWeb.addJavaScriptHandler(
                          handlerName: 'onServerResponse',
                          callback: (args) async{
                            try {
                              final saved = args.isNotEmpty &&
                                  args[0] is Map &&
                                  args[0]['savedata'].toString() == 'true';
                                 print("datw "+ args[0]['savedata'].toString());
                              if (args[0]['savedata'].toString()=="false")  {
                                final server = await _startUnityServer(port: 8080);

                                Navigator.pushAndRemoveUntil(
                                  context,
                                  MaterialPageRoute(builder: (context) =>UnityWebGLApp(server: server,)),
                                      (route) => false,
                                );
                              }
                            } catch (_) {}
                            if (args.isEmpty) return null;
                            try {
                              return args.reduce((curr, next) => curr + next);
                            } catch (_) {
                              return args.first;
                            }
                          },
                        );
                      },
                      onLoadStart: (controller, uri) async {
                        setState(() {
                          _loadStartStamp = DateTime.now().millisecondsSinceEpoch;
                        });
                        final target = uri;
                        if (target != null) {
                          if (_looksLikeBareEmail(target)) {
                            try {
                              await controller.stopLoading();
                            } catch (_) {}
                            final mailto = _convertToMailto(target);
                            await _openMailClient(mailto);
                            return;
                          }
                          final scheme = target.scheme.toLowerCase();
                          if (scheme != 'http' && scheme != 'https') {
                            try {
                              await controller.stopLoading();
                            } catch (_) {}
                          }
                        }
                      },
                      onLoadError: (controller, url, code, message) async {
                        final now = DateTime.now().millisecondsSinceEpoch;
                        final ev = 'InAppWebViewError(code=$code, message=$message)';
                        await blackjackPostStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: url?.toString() ?? '',
                          appSid: _pitBoss.pitBossUid,
                          firstPageLoadTs: _firstPageTimestamp,
                        );
                      },
                      onReceivedHttpError: (controller, request, errorResponse) async {
                        final now = DateTime.now().millisecondsSinceEpoch;
                        final ev = 'HTTPError(status=${errorResponse.statusCode}, reason=${errorResponse.reasonPhrase})';
                        await blackjackPostStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: request.url?.toString() ?? '',
                          appSid: _pitBoss.pitBossUid,
                          firstPageLoadTs: _firstPageTimestamp,
                        );
                      },
                      onReceivedError: (controller, request, error) async {
                        final now = DateTime.now().millisecondsSinceEpoch;
                        final desc = (error.description ?? '').toString();
                        final ev = 'WebResourceError(code=$error, message=$desc)';
                        await blackjackPostStat(
                          event: ev,
                          timeStart: now,
                          timeFinish: now,
                          url: request.url?.toString() ?? '',
                          appSid: _pitBoss.pitBossUid,
                          firstPageLoadTs: _firstPageTimestamp,
                        );
                      },
                      onLoadStop: (controller, uri) async {
                        await controller.evaluateJavascript(source: 'console.log(\'Blackjack table ready!\');');
                        await _pushHandToTable();
                        await _pushPitBossData();

                        setState(() => _currentHandUrl = uri.toString());

                        Future.delayed(const Duration(seconds: 20), () {
                          reportFirstShuffle(url: _currentHandUrl.toString(), timestart: _loadStartStamp);
                        });
                      },
                      shouldOverrideUrlLoading: (controller, action) async {
                        final uri = action.request.url;
                        if (uri == null) return NavigationActionPolicy.ALLOW;

                        if (_looksLikeBareEmail(uri)) {
                          final mailto = _convertToMailto(uri);
                          await _openMailClient(mailto);
                          return NavigationActionPolicy.CANCEL;
                        }

                        final scheme = uri.scheme.toLowerCase();

                        if (scheme == 'mailto') {
                          await _openMailClient(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (scheme == 'tel') {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                          return NavigationActionPolicy.CANCEL;
                        }

                        final host = uri.host.toLowerCase();
                        final isSocial =
                            host.endsWith('facebook.com') ||
                                host.endsWith('instagram.com') ||
                                host.endsWith('twitter.com') ||
                                host.endsWith('x.com');

                        if (isSocial) {
                          await _openExternalApp(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (_isPlatformLane(uri)) {
                          final web = _normalizePlatformUri(uri);
                          await _openExternalApp(web);
                          return NavigationActionPolicy.CANCEL;
                        }

                        if (scheme != 'http' && scheme != 'https') {
                          return NavigationActionPolicy.CANCEL;
                        }

                        return NavigationActionPolicy.ALLOW;
                      },
                      onCreateWindow: (controller, request) async {
                        final uri = request.request.url;
                        if (uri == null) return false;

                        if (_looksLikeBareEmail(uri)) {
                          final mailto = _convertToMailto(uri);
                          await _openMailClient(mailto);
                          return false;
                        }

                        final scheme = uri.scheme.toLowerCase();

                        if (scheme == 'mailto') {
                          await _openMailClient(uri);
                          return false;
                        }

                        if (scheme == 'tel') {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                          return false;
                        }

                        final host = uri.host.toLowerCase();
                        final isSocial =
                            host.endsWith('facebook.com') ||
                                host.endsWith('instagram.com') ||
                                host.endsWith('twitter.com') ||
                                host.endsWith('x.com');

                        if (isSocial) {
                          await _openExternalApp(uri);
                          return false;
                        }

                        if (_isPlatformLane(uri)) {
                          final web = _normalizePlatformUri(uri);
                          await _openExternalApp(web);
                          return false;
                        }

                        if (scheme == 'http' || scheme == 'https') {
                          controller.loadUrl(urlRequest: URLRequest(url: uri));
                        }
                        return false;
                      },
                      onDownloadStartRequest: (controller, request) async {
                        await _openExternalApp(request.url);
                      },
                    ),
                    Visibility(
                      visible: !_veilRaised,
                      child: const BlackjackHourglassLoader(),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// WebView для внешней ссылки (из уведомлений)
class BlackjackLaneScreen extends StatefulWidget with WidgetsBindingObserver {
  final String laneUrl;
  const BlackjackLaneScreen(this.laneUrl, {super.key});

  @override
  State<BlackjackLaneScreen> createState() => _BlackjackLaneScreenState();
}

class _BlackjackLaneScreenState extends State<BlackjackLaneScreen> with WidgetsBindingObserver {
  late InAppWebViewController _laneWeb;

  @override
  Widget build(BuildContext context) {
    final night = MediaQuery.of(context).platformBrightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: night ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: InAppWebView(
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            disableDefaultErrorPage: true,
            mediaPlaybackRequiresUserGesture: false,
            allowsInlineMediaPlayback: true,
            allowsPictureInPictureMediaPlayback: true,
            useOnDownloadStart: true,
            javaScriptCanOpenWindowsAutomatically: true,
            useShouldOverrideUrlLoading: true,
            supportMultipleWindows: true,
          ),
          initialUrlRequest: URLRequest(url: WebUri(widget.laneUrl)),
          onWebViewCreated: (controller) => _laneWeb = controller,
        ),
      ),
    );
  }
}

// ============================================================================


// ============================================================================
// Help экраны: BlackjackHelp
// ============================================================================
class BlackjackHelp extends StatefulWidget {
  const BlackjackHelp({super.key});

  @override
  State<BlackjackHelp> createState() => _BlackjackHelpState();
}

class _BlackjackHelpState extends State<BlackjackHelp> with WidgetsBindingObserver {
  InAppWebViewController? _helpCtrl;
  bool _spinner = true;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            InAppWebView(
              initialFile: 'assets/index.html',
              initialSettings: InAppWebViewSettings(
                javaScriptEnabled: true,
                supportZoom: false,
                disableHorizontalScroll: false,
                disableVerticalScroll: false,
              ),
              onWebViewCreated: (controller) => _helpCtrl = controller,
              onLoadStart: (controller, url) => setState(() => _spinner = true),
              onLoadStop: (controller, url) async => setState(() => _spinner = false),
              onLoadError: (controller, url, code, msg) => setState(() => _spinner = false),
            ),
            if (_spinner) const BlackjackHourglassLoader(),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// main()
