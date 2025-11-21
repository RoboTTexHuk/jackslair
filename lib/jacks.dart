// -----------------------------------------------------------------------------
// Roulette-flavored refactor of the original Caribbean-themed code
// -----------------------------------------------------------------------------

import 'dart:convert';
import 'dart:io';

import 'package:appsflyer_sdk/appsflyer_sdk.dart' show AppsFlyerOptions, AppsflyerSdk;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall, MethodChannel, SystemUiOverlayStyle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:timezone/data/latest.dart' as timezone_data;
import 'package:timezone/timezone.dart' as timezone;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

// Предполагается, что в main.dart эти названия экспортируются.
// Если у вас другие — замените здесь и в местах использования.
import 'main.dart' show MafiaHarbor, CaptainHarbor;

// ============================================================================
// Рулеточная инфраструктура и паттерны
// ============================================================================

class JackWheelLogger {
  const JackWheelLogger();
  void jackLog(Object msg) => debugPrint('[WheelLogger] $msg');
  void jackWarn(Object msg) => debugPrint('[WheelLogger/WARN] $msg');
  void jackErr(Object msg) => debugPrint('[WheelLogger/ERR] $msg');
}

class JackRouletteVault {
  static final JackRouletteVault _jackSingle = JackRouletteVault._();
  JackRouletteVault._();
  factory JackRouletteVault() => _jackSingle;

  final JackWheelLogger jackWheel = const JackWheelLogger();
}

/// Набор рулеточных утилит для маршрутов/почты (CroupierKit)
class JackCroupierKit {
  static bool jackLooksLikeBareMail(Uri jackUri) {
    final jackScheme = jackUri.scheme;
    if (jackScheme.isNotEmpty) return false;
    final jackRaw = jackUri.toString();
    return jackRaw.contains('@') && !jackRaw.contains(' ');
  }

  static Uri jackToMailto(Uri jackUri) {
    final jackFull = jackUri.toString();
    final jackBits = jackFull.split('?');
    final jackWho = jackBits.first;
    final jackQueries = jackBits.length > 1 ? Uri.splitQueryString(jackBits[1]) : <String, String>{};
    return Uri(
      scheme: 'mailto',
      path: jackWho,
      queryParameters: jackQueries.isEmpty ? null : jackQueries,
    );
  }

  static Uri jackGmailize(Uri jackMail) {
    final jackQueries = jackMail.queryParameters;
    final jackParams = <String, String>{
      'view': 'cm',
      'fs': '1',
      if (jackMail.path.isNotEmpty) 'to': jackMail.path,
      if ((jackQueries['subject'] ?? '').isNotEmpty) 'su': jackQueries['subject']!,
      if ((jackQueries['body'] ?? '').isNotEmpty) 'body': jackQueries['body']!,
      if ((jackQueries['cc'] ?? '').isNotEmpty) 'cc': jackQueries['cc']!,
      if ((jackQueries['bcc'] ?? '').isNotEmpty) 'bcc': jackQueries['bcc']!,
    };
    return Uri.https('mail.google.com', '/mail/', jackParams);
  }

  static String jackJustDigits(String jackSource) => jackSource.replaceAll(RegExp(r'[^0-9+]'), '');
}

/// Сервис открытия внешних ссылок/протоколов (RouletteLinker)
class JackRouletteLinker {
  static Future<bool> jackOpen(Uri jackUri) async {
    try {
      if (await launchUrl(jackUri, mode: LaunchMode.inAppBrowserView)) return true;
      return await launchUrl(jackUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('RouletteLinker error: $e; url=$jackUri');
      try {
        return await launchUrl(jackUri, mode: LaunchMode.externalApplication);
      } catch (_) {
        return false;
      }
    }
  }
}

// ============================================================================
// FCM Background Handler — рулеточный крупье в бэкграунде
// ============================================================================
@pragma('vm:entry-point')
Future<void> jackRouletteBgDealer(RemoteMessage jackSpinMsg) async {
  debugPrint("Spin ID: ${jackSpinMsg.messageId}");
  debugPrint("Spin Data: ${jackSpinMsg.data}");
}

// ============================================================================
// Виджет-стол с webview — RouletteTableView
// ============================================================================
class JackRouletteTableView extends StatefulWidget with WidgetsBindingObserver {
  String jackStartingLane;
  JackRouletteTableView(this.jackStartingLane, {super.key});

  @override
  State<JackRouletteTableView> createState() => _JackRouletteTableViewState(jackStartingLane);
}

class _JackRouletteTableViewState extends State<JackRouletteTableView> with WidgetsBindingObserver {
  _JackRouletteTableViewState(this._jackCurrentLane);

  final JackRouletteVault _jackVault = JackRouletteVault();

  late InAppWebViewController _jackWheelController;
  String? _jackPushToken;
  String? _jackDeviceId;
  String? _jackOsBuild;
  String? _jackPlatformKind;
  String? _jackUserLocale;
  String? _jackTimezoneName;
  bool _jackPushEnabled = true;
  bool _jackOverlayBusy = false;
  var _jackGateOpen = true;
  String _jackCurrentLane;
  DateTime? _jackLastPausedAt;

  final Set<String> _jackExternalHosts = {
    't.me',
    'telegram.me',
    'telegram.dog',
    'wa.me',
    'api.whatsapp.com',
    'chat.whatsapp.com',
    'bnl.com',
    'www.bnl.com',
  };
  final Set<String> _jackExternalSchemes = {'tg', 'telegram', 'whatsapp', 'bnl'};

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addObserver(this);
    FirebaseMessaging.onBackgroundMessage(jackRouletteBgDealer);

    _jackInitPushAndToken();
    _jackScanDeviceDeck();
    _jackWireForegroundPushHandlers();
    _jackBindPlatformNotificationTap();

    Future.delayed(const Duration(seconds: 2), () {});
    Future.delayed(const Duration(seconds: 6), () {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState jackState) {
    if (jackState == AppLifecycleState.paused) {
      _jackLastPausedAt = DateTime.now();
    }
    if (jackState == AppLifecycleState.resumed) {
      if (Platform.isIOS && _jackLastPausedAt != null) {
        final jackNow = DateTime.now();
        final jackDrift = jackNow.difference(_jackLastPausedAt!);
        if (jackDrift > const Duration(minutes: 25)) {
          _jackForceReloadToLobby();
        }
      }
      _jackLastPausedAt = null;
    }
  }

  void _jackForceReloadToLobby() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
    });
  }

  void _jackWireForegroundPushHandlers() {
    FirebaseMessaging.onMessage.listen((RemoteMessage jackMsg) {
      if (jackMsg.data['uri'] != null) {
        _jackNavigateTo(jackMsg.data['uri'].toString());
      } else {
        _jackReturnToCurrentLane();
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage jackMsg) {
      if (jackMsg.data['uri'] != null) {
        _jackNavigateTo(jackMsg.data['uri'].toString());
      } else {
        _jackReturnToCurrentLane();
      }
    });
  }

  void _jackNavigateTo(String jackNewLane) async {
    await _jackWheelController.loadUrl(urlRequest: URLRequest(url: WebUri(jackNewLane)));
  }

  void _jackReturnToCurrentLane() async {
    Future.delayed(const Duration(seconds: 3), () {
      _jackWheelController.loadUrl(urlRequest: URLRequest(url: WebUri(_jackCurrentLane)));
    });
  }

  Future<void> _jackInitPushAndToken() async {
    FirebaseMessaging jackFm = FirebaseMessaging.instance;
    await jackFm.requestPermission(alert: true, badge: true, sound: true);
    _jackPushToken = await jackFm.getToken();
  }

  Future<void> _jackScanDeviceDeck() async {
    try {
      final jackDeviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final jackAndroidInfo = await jackDeviceInfo.androidInfo;
        _jackDeviceId = jackAndroidInfo.id;
        _jackPlatformKind = "android";
        _jackOsBuild = jackAndroidInfo.version.release;
      } else if (Platform.isIOS) {
        final jackIosInfo = await jackDeviceInfo.iosInfo;
        _jackDeviceId = jackIosInfo.identifierForVendor;
        _jackPlatformKind = "ios";
        _jackOsBuild = jackIosInfo.systemVersion;
      }
      final jackPackageInfo = await PackageInfo.fromPlatform();
      _jackUserLocale = Platform.localeName.split('_')[0];
      _jackTimezoneName = timezone.local.name;
    } catch (e) {
      debugPrint("Device Scan Error: $e");
    }
  }

  void _jackBindPlatformNotificationTap() {
    MethodChannel('com.example.fcm/notification').setMethodCallHandler((MethodCall jackCall) async {
      if (jackCall.method == "onNotificationTap") {
        final Map<String, dynamic> jackPayload = Map<String, dynamic>.from(jackCall.arguments);
        debugPrint("URI from platform tap: ${jackPayload['uri']}");
        final jackUri = jackPayload["uri"]?.toString();
        if (jackUri != null && !jackUri.contains("Нет URI")) {
          Navigator.pushAndRemoveUntil(
            context,
            MaterialPageRoute(builder: (context) => JackRouletteTableView(jackUri)),
                (route) => false,
          );
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    _jackBindPlatformNotificationTap();

    final jackDark = MediaQuery.of(context).platformBrightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: jackDark ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            InAppWebView(
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
              initialUrlRequest: URLRequest(url: WebUri(_jackCurrentLane)),
              onWebViewCreated: (jackController) {
                _jackWheelController = jackController;

                _jackWheelController.addJavaScriptHandler(
                  handlerName: 'onServerResponse',
                  callback: (jackArgs) {
                    _jackVault.jackWheel.jackLog("JS Args: $jackArgs");
                    try {
                      return jackArgs.reduce((jackValue, jackNext) => jackValue + jackNext);
                    } catch (_) {
                      return jackArgs.toString();
                    }
                  },
                );
              },
              onLoadStart: (jackController, jackUri) async {
                if (jackUri != null) {
                  if (JackCroupierKit.jackLooksLikeBareMail(jackUri)) {
                    try {
                      await jackController.stopLoading();
                    } catch (_) {}
                    final jackMailto = JackCroupierKit.jackToMailto(jackUri);
                    await JackRouletteLinker.jackOpen(JackCroupierKit.jackGmailize(jackMailto));
                    return;
                  }
                  final jackScheme = jackUri.scheme.toLowerCase();
                  if (jackScheme != 'http' && jackScheme != 'https') {
                    try {
                      await jackController.stopLoading();
                    } catch (_) {}
                  }
                }
              },
              onLoadStop: (jackController, jackUri) async {
                await jackController.evaluateJavascript(source: "console.log('Hello from Roulette JS!');");
              },
              shouldOverrideUrlLoading: (jackController, jackNav) async {
                final jackUri = jackNav.request.url;
                if (jackUri == null) return NavigationActionPolicy.ALLOW;

                if (JackCroupierKit.jackLooksLikeBareMail(jackUri)) {
                  final jackMailto = JackCroupierKit.jackToMailto(jackUri);
                  await JackRouletteLinker.jackOpen(JackCroupierKit.jackGmailize(jackMailto));
                  return NavigationActionPolicy.CANCEL;
                }

                final jackScheme = jackUri.scheme.toLowerCase();
                if (jackScheme == 'mailto') {
                  await JackRouletteLinker.jackOpen(JackCroupierKit.jackGmailize(jackUri));
                  return NavigationActionPolicy.CANCEL;
                }

                if (_jackIsExternalTable(jackUri)) {
                  await JackRouletteLinker.jackOpen(_jackMapExternalToHttp(jackUri));
                  return NavigationActionPolicy.CANCEL;
                }

                if (jackScheme != 'http' && jackScheme != 'https') {
                  return NavigationActionPolicy.CANCEL;
                }
                return NavigationActionPolicy.ALLOW;
              },
              onCreateWindow: (jackController, jackRequest) async {
                final jackUri = jackRequest.request.url;
                if (jackUri == null) return false;

                if (JackCroupierKit.jackLooksLikeBareMail(jackUri)) {
                  final jackMailto = JackCroupierKit.jackToMailto(jackUri);
                  await JackRouletteLinker.jackOpen(JackCroupierKit.jackGmailize(jackMailto));
                  return false;
                }

                final jackScheme = jackUri.scheme.toLowerCase();
                if (jackScheme == 'mailto') {
                  await JackRouletteLinker.jackOpen(JackCroupierKit.jackGmailize(jackUri));
                  return false;
                }

                if (_jackIsExternalTable(jackUri)) {
                  await JackRouletteLinker.jackOpen(_jackMapExternalToHttp(jackUri));
                  return false;
                }

                if (jackScheme == 'http' || jackScheme == 'https') {
                  jackController.loadUrl(urlRequest: URLRequest(url: jackUri));
                }
                return false;
              },
            ),
            if (_jackOverlayBusy)
              Positioned.fill(
                child: Container(
                  color: Colors.black87,
                  child: Center(
                    child: CircularProgressIndicator(
                      backgroundColor: Colors.grey.shade800,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
                      strokeWidth: 6,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _jackIsExternalTable(Uri jackUri) {
    final jackScheme = jackUri.scheme.toLowerCase();
    if (_jackExternalSchemes.contains(jackScheme)) return true;

    if (jackScheme == 'http' || jackScheme == 'https') {
      final jackHost = jackUri.host.toLowerCase();
      if (_jackExternalHosts.contains(jackHost)) return true;
    }
    return false;
  }

  Uri _jackMapExternalToHttp(Uri jackUri) {
    final jackScheme = jackUri.scheme.toLowerCase();

    if (jackScheme == 'tg' || jackScheme == 'telegram') {
      final jackQueries = jackUri.queryParameters;
      final jackDomain = jackQueries['domain'];
      if (jackDomain != null && jackDomain.isNotEmpty) {
        return Uri.https('t.me', '/$jackDomain', {
          if (jackQueries['start'] != null) 'start': jackQueries['start']!,
        });
      }
      final jackPath = jackUri.path.isNotEmpty ? jackUri.path : '';
      return Uri.https('t.me', '/$jackPath', jackUri.queryParameters.isEmpty ? null : jackUri.queryParameters);
    }

    if (jackScheme == 'whatsapp') {
      final jackQueries = jackUri.queryParameters;
      final jackPhone = jackQueries['phone'];
      final jackText = jackQueries['text'];
      if (jackPhone != null && jackPhone.isNotEmpty) {
        return Uri.https('wa.me', '/${JackCroupierKit.jackJustDigits(jackPhone)}', {
          if (jackText != null && jackText.isNotEmpty) 'text': jackText,
        });
      }
      return Uri.https('wa.me', '/', {if (jackText != null && jackText.isNotEmpty) 'text': jackText});
    }

    if (jackScheme == 'bnl') {
      final jackNewPath = jackUri.path.isNotEmpty ? jackUri.path : '';
      return Uri.https('bnl.com', '/$jackNewPath', jackUri.queryParameters.isEmpty ? null : jackUri.queryParameters);
    }

    return jackUri;
  }
}