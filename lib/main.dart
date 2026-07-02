import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import 'package:http/http.dart' as http;
import 'package:screen_retriever/screen_retriever.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

// ==========================================
// SYSTEM THEMES & CORES
// ==========================================
class Sys {
  static const blue   = Color(0xFF0A84FF);
  static const green  = Color(0xFF30D158);
  static const red    = Color(0xFFFF453A);
  static const orange = Color(0xFFFF9F0A);
  static const yellow = Color(0xFFFFD60A);
  static const purple = Color(0xFFBF5AF2);
  static const pink   = Color(0xFFFF375F);
  static const indigo = Color(0xFF5E5CE6);
  static const teal   = Color(0xFF64D2FF);
  static const mint   = Color(0xFF66D4CF);
  static const gray   = Color(0xFF98989D);
}

class SiriGlow {
  static const sweep = [Sys.blue, Sys.purple, Sys.pink, Sys.orange, Color(0xFF5AC8FA), Sys.blue];
}

class Glass {
  static const fill          = Color(0xCC1C1C1E);
  static const fillSubtle    = Color(0x4D1C1C1E);
  static const border        = Color(0x40FFFFFF);
  static const borderSubtle  = Color(0x1FFFFFFF);
  static const highlight     = Color(0x60FFFFFF);
  static const shadow        = Color(0x52000000);
}

const double kWindowWidth   = 760;
const double kWindowHeight  = 600;
const double kIslandCompactW  = 180;
const double kIslandCompactH  = 36;
const double kIslandExpandedH = 58;

class SiriHaloPainter extends CustomPainter {
  final double radius, rotation, intensity;
  const SiriHaloPainter({required this.radius, required this.rotation, required this.intensity});

  @override
  void paint(Canvas canvas, Size size) {
    if (intensity <= 0.01) return;
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final colors = SiriGlow.sweep.map((c) => c.withOpacity(intensity)).toList();
    final gradient = SweepGradient(colors: colors, transform: GradientRotation(rotation));

    canvas.drawRRect(rrect.inflate(2), Paint()..shader = gradient.createShader(rect)..style = PaintingStyle.stroke..strokeWidth = 16..maskFilter = const MaskFilter.blur(BlurStyle.outer, 26));
    canvas.drawRRect(rrect.inflate(0.8), Paint()..shader = gradient.createShader(rect)..style = PaintingStyle.stroke..strokeWidth = 2.4..maskFilter = const MaskFilter.blur(BlurStyle.outer, 5));
  }

  @override
  bool shouldRepaint(covariant SiriHaloPainter old) => old.rotation != rotation || old.intensity != intensity || old.radius != radius;
}

// Draws the island's own shape/fill/border, replacing a plain rounded
// pill. Compact (idle) state is a real hardware-notch shape: flat top
// edge with sharp top-left/top-right corners flush against the screen
// bezel (no bevel, no gap), and only the bottom two corners rounded -
// same silhouette as a laptop's camera notch. Expanded state stays a
// normal rounded rectangle.
class IslandShapePainter extends CustomPainter {
  final bool expanded;
  const IslandShapePainter({required this.expanded});

  Path _notchPath(Size size) {
    final w = size.width, h = size.height;
    final radius = math.min(16.0, math.min(w, h) / 2);
    final path = Path();
    path.moveTo(0, 0);
    path.lineTo(w, 0);
    path.lineTo(w, h - radius);
    path.quadraticBezierTo(w, h, w - radius, h);
    path.lineTo(radius, h);
    path.quadraticBezierTo(0, h, 0, h - radius);
    path.close();
    return path;
  }

  Path _roundedPath(Size size) {
    final path = Path();
    path.addRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20)));
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final path = expanded ? _roundedPath(size) : _notchPath(size);

    canvas.drawPath(
      path,
      Paint()
        ..color = expanded ? const Color(0xCC121214) : const Color(0xF0060607)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white.withOpacity(0.1)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(covariant IslandShapePainter old) => old.expanded != expanded;
}

Widget winLogo({double size = 16, double opacity = 1.0, AnimationController? pulse}) {
  final icon = Image.asset(
    'assets/window.png',
    width:size,
    height:size,
    color:Colors.white.withOpacity(opacity)
  );
  if (pulse == null) return icon;
  return AnimatedBuilder(
    animation: pulse,
    builder: (_, _) => Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: 1.0 + (math.sin(pulse.value * 2 * math.pi) * 0.05),
        child: icon,
      ),
    ),
  );
}

class LiquidGlass extends StatelessWidget {
  final Widget? child;
  final double borderRadius, blur, borderWidth;
  final Color fill, border;
  final EdgeInsetsGeometry? padding;
  final double? width;

  const LiquidGlass({
    super.key, this.child, this.borderRadius = 20, this.blur = 34, this.fill = Glass.fill,
    this.border = Glass.border, this.borderWidth = 0.6, this.padding, this.width,
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return Container(
      width: width,
      decoration: BoxDecoration(borderRadius: radius, boxShadow: const [BoxShadow(color: Glass.shadow, blurRadius: 32, spreadRadius: -4, offset: Offset(0, 12))]),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(color: fill, borderRadius: radius, border: Border.all(color: border, width: borderWidth)),
            child: child,
          ),
        ),
      ),
    );
  }
}

class GlassChip extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool active;
  final double radius;

  const GlassChip({super.key, required this.child, this.onTap, this.active = false, this.radius = 10});

  @override
  State<GlassChip> createState() => _GlassChipState();
}

class _GlassChipState extends State<GlassChip> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.92 : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: widget.active ? Sys.blue.withOpacity(0.22) : Glass.fillSubtle,
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(color: widget.active ? Sys.blue.withOpacity(0.45) : Glass.borderSubtle, width: 0.5),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class GlassToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  final Color activeColor;
  const GlassToggle({super.key, required this.value, this.onChanged, this.activeColor = Sys.green});

  @override
  Widget build(BuildContext context) {
    return Switch(
      value: value,
      onChanged: onChanged,
      activeColor: Colors.white,
      activeTrackColor: activeColor,
      inactiveTrackColor: Glass.fillSubtle,
      inactiveThumbColor: Colors.grey,
    );
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  double screenWidth = 1920;
  try {
    final display = await ScreenRetriever.instance.getPrimaryDisplay();
    if (display.size.width > 0) screenWidth = display.size.width;
  } catch (_) {}

  await windowManager.waitUntilReadyToShow(WindowOptions(
    size: const Size(kWindowWidth, 40),
    center: false,
    backgroundColor: Colors.transparent,
    skipTaskbar: true,
    titleBarStyle: TitleBarStyle.hidden,
  ), () async {
    await windowManager.setPosition(Offset((screenWidth - kWindowWidth) / 2, 0));
    await windowManager.show();
    await windowManager.setAsFrameless();
    await windowManager.setAlwaysOnTop(true);
  });
  runApp(const DynamicIslandApp());
}

class DynamicIslandApp extends StatelessWidget {
  const DynamicIslandApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        textTheme: const TextTheme().apply(bodyColor: Colors.white, displayColor: Colors.white),
      ),
      home: const DynamicIslandScreen(),
    );
  }
}

enum IslandPanel { none, wifi, volume, battery, apps, media, search, bluetooth }

class DynamicIslandScreen extends StatefulWidget {
  const DynamicIslandScreen({super.key});
  @override
  State<DynamicIslandScreen> createState() => _DynamicIslandScreenState();
}

class _DynamicIslandScreenState extends State<DynamicIslandScreen> with TickerProviderStateMixin {
  IslandPanel _activePanel = IslandPanel.none;
  bool _isExpanded = false;
  Timer? _hideTimer;
  String _clockText = "00:00";

  bool _wifiEnabled = true;
  String _wifiSSID = "";
  List<Map<String, dynamic>> _wifiNetworks = [];
  bool _scanningWifi = false;
  String? _connectingSsid;
  bool _bluetoothEnabled = true;
  String _bluetoothStatusText = "";
  List<Map<String, dynamic>> _bluetoothDevices = [];
  bool _scanningBluetooth = false;
  List<Map<String, dynamic>> _nearbyBluetoothDevices = [];
  bool _scanningNearby = false;
  List<Map<String, dynamic>> _audioOutputDevices = [];
  bool _audioModuleInstalled = true;
  bool _loadingAudioDevices = false;
  int? _switchingAudioDeviceIndex;
  Map<String, dynamic>? _nowPlaying;
  Timer? _nowPlayingTimer;
  Map<String, dynamic>? _batteryStatus;
  List<Map<String, dynamic>> _powerPlans = [];
  bool _loadingPowerPlans = false;
  String? _switchingPlanGuid;
  Timer? _batteryPollTimer;
  double _volume = 60;
  double _brightness = 80;
  int _batteryPercent = 100;
  String _searchQuery = "";

  // Spotlight-style search state
  int _selectedIndex = 0;
  final FocusNode _searchFieldFocus = FocusNode();

  List<Map<String, dynamic>> _discoveredApps = [];

  // Quick Actions panel state
  List<Map<String, dynamic>> _quickActions = [];
  bool _editingQuickActions = false;
  bool _addingAction = false;
  bool _darkModeOn = true;
  String? _pendingConfirmAction;
  Timer? _confirmTimer;
  final TextEditingController _addActionController = TextEditingController();
  List<Map<String, dynamic>> _addActionResults = [];

  late AnimationController _pulseCtrl, _siriCtrl, _siriIntensityCtrl;
  final TextEditingController _siriField = TextEditingController();

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))..repeat(reverse: true);
    _siriCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
    _siriIntensityCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 420));
    Timer.periodic(const Duration(seconds: 1), (_) => _tickClock());
    _tickClock();
    _syncHardwareStates();
    _fetchWifiStatus();
    _fetchWifiNetworks();
    _fetchBluetoothStatus();
    _fetchBluetoothDevices();
    _fetchQuickActions();
    _fetchDarkMode();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _confirmTimer?.cancel();
    _nowPlayingTimer?.cancel();
    _batteryPollTimer?.cancel();
    _pulseCtrl.dispose();
    _siriCtrl.dispose();
    _siriIntensityCtrl.dispose();
    _siriField.dispose();
    _searchFieldFocus.dispose();
    _addActionController.dispose();
    super.dispose();
  }

  void _tickClock() {
    final now = DateTime.now();
    if (mounted) {
      setState(() => _clockText = "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}");
    }
  }

  Future<void> _syncHardwareStates() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/system/status'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _wifiEnabled = data['wifi_enabled'] ?? true;
          _bluetoothEnabled = data['bluetooth_enabled'] ?? true;
          _volume = (data['volume'] ?? 60).toDouble();
          _brightness = (data['brightness'] ?? 80).toDouble();
          _batteryPercent = data['battery_percent'] ?? 100;
        });
      }
    } catch (e) {
      print("System sync idle: $e");
    }
  }

  // ── Wi-Fi networking ─────────────────────────────────────────────
  Future<void> _fetchWifiStatus() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/wifi/status'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _wifiEnabled = data['enabled'] ?? _wifiEnabled;
          _wifiSSID = data['ssid'] ?? "";
        });
      }
    } catch (e) {
      print("Wi-Fi status sync idle: $e");
    }
  }

  Future<void> _toggleWifi() async {
    try {
      final res = await http.post(Uri.parse('http://127.0.0.1:8000/api/wifi/toggle'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => _wifiEnabled = data['enabled'] ?? !_wifiEnabled);
      }
    } catch (e) {
      print("Wi-Fi toggle failed: $e");
    }
    // Pull the fresh SSID/status now that the radio state may have changed.
    await _fetchWifiStatus();
  }

  Future<void> _fetchWifiNetworks() async {
    setState(() => _scanningWifi = true);
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/wifi/networks'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> nets = data['networks'] ?? [];
        setState(() => _wifiNetworks = nets.map((n) => Map<String, dynamic>.from(n)).toList());
      }
    } catch (e) {
      print("Wi-Fi scan idle: $e");
    }
    if (mounted) setState(() => _scanningWifi = false);
  }

  Future<void> _connectToNetwork(String ssid, {String? password}) async {
    setState(() => _connectingSsid = ssid);
    try {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/wifi/connect'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"ssid": ssid, if (password != null) "password": password}),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['ok'] != true) {
          print("Wi-Fi connect failed: ${data['message']}");
        }
      }
    } catch (e) {
      print("Wi-Fi connect request failed: $e");
    }
    if (mounted) setState(() => _connectingSsid = null);
    await _fetchWifiStatus();
    await _fetchWifiNetworks();
  }

  void _onTapNetwork(Map<String, dynamic> net) {
    final ssid = net['ssid'] as String;
    final secured = net['secured'] == true;
    final saved = net['saved'] == true;
    // Already-saved networks (or open ones) connect straight away —
    // Windows already knows the password for saved profiles.
    if (!secured || saved) {
      _connectToNetwork(ssid);
    } else {
      _showWifiPasswordDialog(ssid);
    }
  }

  Future<void> _showWifiPasswordDialog(String ssid) async {
    final controller = TextEditingController();
    bool obscure = true;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(ssid, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
          content: TextField(
            controller: controller,
            obscureText: obscure,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              hintText: "Password",
              hintStyle: TextStyle(color: Colors.white.withOpacity(0.35)),
              suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility_off_rounded : Icons.visibility_rounded, color: Colors.grey, size: 18),
                onPressed: () => setDialogState(() => obscure = !obscure),
              ),
            ),
            onSubmitted: (_) => Navigator.of(ctx).pop(controller.text),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text("Connect", style: TextStyle(color: Sys.blue)),
            ),
          ],
        ),
      ),
    );
    if (result != null && result.isNotEmpty) {
      _connectToNetwork(ssid, password: result);
    }
  }

  // ── Bluetooth networking ────────────────────────────────────────
  Future<void> _fetchBluetoothStatus() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/bluetooth/status'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _bluetoothEnabled = data['enabled'] ?? _bluetoothEnabled;
          _bluetoothStatusText = data['status_text'] ?? "";
        });
      }
    } catch (e) {
      print("Bluetooth status sync idle: $e");
    }
  }

  Future<void> _toggleBluetooth() async {
    try {
      final res = await http.post(Uri.parse('http://127.0.0.1:8000/api/bluetooth/toggle'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => _bluetoothEnabled = data['enabled'] ?? !_bluetoothEnabled);
      }
    } catch (e) {
      print("Bluetooth toggle failed: $e");
    }
    await _fetchBluetoothStatus();
    await _fetchBluetoothDevices();
  }

  Future<void> _fetchBluetoothDevices() async {
    setState(() => _scanningBluetooth = true);
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/bluetooth/devices'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> devs = data['devices'] ?? [];
        setState(() => _bluetoothDevices = devs.map((d) => Map<String, dynamic>.from(d)).toList());
      }
    } catch (e) {
      print("Bluetooth device scan idle: $e");
    }
    if (mounted) setState(() => _scanningBluetooth = false);
  }

  Future<void> _scanNearbyBluetooth() async {
    setState(() => _scanningNearby = true);
    try {
      // This inquiry takes ~10s on the backend - that's normal.
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/bluetooth/scan'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> devs = data['devices'] ?? [];
        setState(() {
          _nearbyBluetoothDevices = devs
              .map((d) => Map<String, dynamic>.from(d))
              .where((d) => d['paired'] != true)
              .toList();
        });
      }
    } catch (e) {
      print("Bluetooth nearby scan idle: $e");
    }
    if (mounted) setState(() => _scanningNearby = false);
  }

  Future<void> _pairBluetoothDevice(String name) async {
    try {
      // Actual pairing (PIN/confirmation) is handled by Windows' native
      // dialog rather than reimplemented here - it's the reliable path.
      await http.post(Uri.parse('http://127.0.0.1:8000/api/bluetooth/pair'));
    } catch (e) {
      print("Bluetooth pair launch failed: $e");
    }
  }

  // ── Audio output device networking ───────────────────────────────
  Future<void> _fetchAudioDevices() async {
    setState(() => _loadingAudioDevices = true);
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/audio/devices'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> devs = data['devices'] ?? [];
        setState(() {
          _audioOutputDevices = devs.map((d) => Map<String, dynamic>.from(d)).toList();
          _audioModuleInstalled = data['module_installed'] ?? true;
        });
      }
    } catch (e) {
      print("Audio device fetch idle: $e");
    }
    if (mounted) setState(() => _loadingAudioDevices = false);
  }

  Future<void> _switchAudioDevice(int index) async {
    setState(() => _switchingAudioDeviceIndex = index);
    try {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/audio/set-device'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"index": index}),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> devs = data['devices'] ?? [];
        setState(() => _audioOutputDevices = devs.map((d) => Map<String, dynamic>.from(d)).toList());
      }
    } catch (e) {
      print("Audio device switch failed: $e");
    }
    if (mounted) setState(() => _switchingAudioDeviceIndex = null);
  }

  // ── Now Playing / media transport ──────────────────────────────
  Future<void> _fetchNowPlaying() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/media/now-playing'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => _nowPlaying = data['active'] == true ? Map<String, dynamic>.from(data) : null);
      }
    } catch (e) {
      print("Now Playing fetch idle: $e");
    }
  }

  void _startNowPlayingPolling() {
    _nowPlayingTimer?.cancel();
    _fetchNowPlaying();
    _nowPlayingTimer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchNowPlaying());
  }

  void _stopNowPlayingPolling() {
    _nowPlayingTimer?.cancel();
    _nowPlayingTimer = null;
  }

  Future<void> _mediaTogglePlayPause() async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/media/play-pause'));
    } catch (e) {
      print("Media play/pause failed: $e");
    }
    await Future.delayed(const Duration(milliseconds: 250));
    await _fetchNowPlaying();
  }

  Future<void> _mediaNext() async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/media/next'));
    } catch (e) {
      print("Media next failed: $e");
    }
    await Future.delayed(const Duration(milliseconds: 250));
    await _fetchNowPlaying();
  }

  Future<void> _mediaPrevious() async {
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000/api/media/previous'));
    } catch (e) {
      print("Media previous failed: $e");
    }
    await Future.delayed(const Duration(milliseconds: 250));
    await _fetchNowPlaying();
  }

  // ── Battery / power plan networking ────────────────────────────
  Future<void> _fetchBatteryStatus() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/power/status'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _batteryStatus = data;
          if (data['available'] == true) {
            _batteryPercent = data['percent'] ?? _batteryPercent;
          }
        });
      }
    } catch (e) {
      print("Battery status fetch idle: $e");
    }
  }

  void _startBatteryPolling() {
    _batteryPollTimer?.cancel();
    _fetchBatteryStatus();
    _batteryPollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _fetchBatteryStatus());
  }

  void _stopBatteryPolling() {
    _batteryPollTimer?.cancel();
    _batteryPollTimer = null;
  }

  Future<void> _fetchPowerPlans() async {
    setState(() => _loadingPowerPlans = true);
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/power/plans'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> plans = data['plans'] ?? [];
        setState(() => _powerPlans = plans.map((p) => Map<String, dynamic>.from(p)).toList());
      }
    } catch (e) {
      print("Power plan fetch idle: $e");
    }
    if (mounted) setState(() => _loadingPowerPlans = false);
  }

  Future<void> _switchPowerPlan(String guid) async {
    setState(() => _switchingPlanGuid = guid);
    try {
      final res = await http.post(
        Uri.parse('http://127.0.0.1:8000/api/power/set'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"guid": guid}),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> plans = data['plans'] ?? [];
        setState(() => _powerPlans = plans.map((p) => Map<String, dynamic>.from(p)).toList());
      }
    } catch (e) {
      print("Power plan switch failed: $e");
    }
    if (mounted) setState(() => _switchingPlanGuid = null);
  }

  void _show() async {
    _hideTimer?.cancel();
    if (!_isExpanded) {
      setState(() => _isExpanded = true);
      await windowManager.setSize(const Size(kWindowWidth, kWindowHeight));
      await windowManager.setIgnoreMouseEvents(false);
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 1200), () async {
      if (!mounted) return;
      if (FocusScope.of(context).hasFocus && _activePanel == IslandPanel.search) return;
      setState(() { _isExpanded = false; _activePanel = IslandPanel.none; });
      _siriIntensityCtrl.reverse();
      _stopNowPlayingPolling();
      _stopBatteryPolling();
      await windowManager.setSize(const Size(kWindowWidth, 40));
    });
  }

  void _openPanel(IslandPanel p) {
    _show();
    setState(() {
      _activePanel = (_activePanel == p) ? IslandPanel.none : p;
      _editingQuickActions = false;
      _addingAction = false;
    });
    if (p == IslandPanel.search) _siriIntensityCtrl.forward(); else _siriIntensityCtrl.reverse();
    if (p == IslandPanel.apps) {
      _fetchQuickActions();
      _fetchDarkMode();
    }
    if (p == IslandPanel.wifi) {
      _fetchWifiStatus();
      _fetchWifiNetworks();
    }
    if (p == IslandPanel.bluetooth) {
      _fetchBluetoothStatus();
      _fetchBluetoothDevices();
    }
    if (p == IslandPanel.volume) {
      _fetchAudioDevices();
    }
    if (p == IslandPanel.media) {
      _startNowPlayingPolling();
    } else {
      _stopNowPlayingPolling();
    }
    if (p == IslandPanel.battery) {
      _startBatteryPolling();
      _fetchPowerPlans();
    } else {
      _stopBatteryPolling();
    }
  }

  // ── Quick Actions networking ────────────────────────────────────
  Future<void> _fetchQuickActions() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/quickactions'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => _quickActions = List<Map<String, dynamic>>.from(data['items']));
      }
    } catch (e) {
      print("Quick actions sync idle: $e");
    }
  }

  Future<void> _fetchDarkMode() async {
    try {
      final res = await http.get(Uri.parse('http://127.0.0.1:8000/api/actions/darkmode'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => _darkModeOn = data['dark_mode'] ?? true);
      }
    } catch (e) {
      print("Dark mode sync idle: $e");
    }
  }

  Future<void> _toggleDarkMode() async {
    try {
      final res = await http.post(Uri.parse('http://127.0.0.1:8000/api/actions/darkmode/toggle'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() => _darkModeOn = data['dark_mode'] ?? _darkModeOn);
      }
    } catch (e) {
      print("Dark mode toggle failed: $e");
    }
  }

  void _handleSystemAction(String action) async {
    final destructive = action == 'restart' || action == 'shutdown';
    if (destructive && _pendingConfirmAction != action) {
      setState(() => _pendingConfirmAction = action);
      _confirmTimer?.cancel();
      _confirmTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _pendingConfirmAction = null);
      });
      return;
    }
    _confirmTimer?.cancel();
    setState(() => _pendingConfirmAction = null);

    final endpoints = {
      'screenshot': '/api/actions/screenshot',
      'lock': '/api/power/lock',
      'sleep': '/api/power/sleep',
      'restart': '/api/power/restart',
      'shutdown': '/api/power/shutdown',
    };
    final endpoint = endpoints[action];
    if (endpoint == null) return;
    try {
      await http.post(Uri.parse('http://127.0.0.1:8000$endpoint'));
    } catch (e) {
      print("System action '$action' failed: $e");
    }
    if (!destructive) _scheduleHide();
  }

  Future<void> _launchQuickAction(Map<String, dynamic> item) async {
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/apps/launch'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"exe": item['action']}),
      );
    } catch (e) {
      print("Quick action launch failed: $e");
    }
    _scheduleHide();
  }

  Future<void> _removeQuickAction(String name) async {
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/quickactions/remove'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({"name": name}),
      );
    } catch (e) {
      print("Quick action remove failed: $e");
    }
    await _fetchQuickActions();
  }

  Future<void> _addQuickAction(Map<String, dynamic> item) async {
    try {
      await http.post(
        Uri.parse('http://127.0.0.1:8000/api/quickactions/add'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "name": item['name'],
          "action": item['action'],
          "type": item['type'] == 'Action' ? 'action' : 'app',
        }),
      );
    } catch (e) {
      print("Quick action add failed: $e");
    }
    setState(() {
      _addingAction = false;
      _addActionResults = [];
      _addActionController.clear();
    });
    await _fetchQuickActions();
  }

  Future<void> _searchForAdd(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _addActionResults = []);
      return;
    }
    try {
      final url = Uri.parse('http://127.0.0.1:8000/api/search?q=${Uri.encodeComponent(query)}');
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final List<dynamic> results = data['results'];
        setState(() => _addActionResults = results
            .map((e) => {'name': e['name'], 'type': e['type'], 'action': e['action']})
            .toList());
      }
    } catch (e) {
      print("Add-action search failed: $e");
    }
  }

  // ── Network Connectors ─────────────────────────────────────────
  Future<void> _fetchBackendResults(String query) async {
    if (query.trim().isEmpty) {
      setState(() {
        _discoveredApps = [];
        _selectedIndex = 0;
      });
      return;
    }
    try {
      final url = Uri.parse('http://127.0.0.1:8000/api/search?q=${Uri.encodeComponent(query)}');
      final response = await http.get(url);
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<dynamic> results = data['results'];
        setState(() {
          _discoveredApps = results.map((item) => {
            'name': item['name'],
            'type': item['type'],
            'icon': item['type'] == 'Action' ? Icons.flash_on : Icons.apps_rounded,
            'action': item['action']
          }).toList();
          _selectedIndex = 0;
        });
      }
    } catch (e) {
      print("Search channel connection fault: $e");
    }
  }

  // Flat list used for both rendering and keyboard navigation:
  // app/action results followed by the web-search fallback row.
  List<Map<String, dynamic>> _spotlightItems() {
    final items = List<Map<String, dynamic>>.from(_discoveredApps);
    items.add({
      'name': 'Search web for "$_searchQuery"',
      'type': 'Google Search',
      'icon': Icons.travel_explore,
      'isWeb': true,
    });
    return items;
  }

  void _runSelected() {
    final items = _spotlightItems();
    if (_selectedIndex < 0 || _selectedIndex >= items.length) return;
    final item = items[_selectedIndex];
    if (item['isWeb'] == true) {
      _launchWebSearch(_searchQuery);
    } else {
      _executeSpotlightAction(item);
    }
  }

  void _executeSpotlightAction(Map<String, dynamic> item) async {
    final action = item['action'].toString();
    final type = item['type'].toString();

    if (type == 'Action') {
      if (action == 'wifi_toggle') {
        await _toggleWifi();
      } else if (action == 'volume_mute') {
        setState(() => _volume = 0);
        await http.post(Uri.parse('http://127.0.0.1:8000/api/volume/mute'),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"muted": true})
        );
      }
    } else {
      // It's a real PC app! Send it to the backend to launch.
      try {
        await http.post(
          Uri.parse('http://127.0.0.1:8000/api/apps/launch'),
          headers: {"Content-Type": "application/json"},
          body: jsonEncode({"exe": action}),
        );
      } catch (e) {
        print("Failed application launcher pipeline: $e");
      }
    }

    _siriField.clear();
    setState(() => _searchQuery = "");
    _scheduleHide();
  }

  void _launchWebSearch(String query) async {
    final Uri searchUri = Uri.parse('https://www.google.com/search?q=${Uri.encodeComponent(query)}');
    if (await canLaunchUrl(searchUri)) {
      await launchUrl(searchUri);
    }
    _siriField.clear();
    setState(() => _searchQuery = "");
    _scheduleHide();
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final expandedW = (screenW * 0.6).clamp(600.0, 700.0);
    final panelW = _activePanel == IslandPanel.search
        ? (screenW * 0.42).clamp(440.0, 560.0)
        : (screenW * 0.35).clamp(360.0, 440.0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        color: Colors.transparent,
        alignment: Alignment.topCenter,
        child: MouseRegion(
          onEnter: (_) => _show(),
          onExit: (_) => _scheduleHide(),
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildBar(expandedW),
                if (_activePanel != IslandPanel.none)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Material(
                      color: Colors.transparent,
                      child: LiquidGlass(
                        width: panelW,
                        padding: const EdgeInsets.all(16),
                        child: _buildPanelBody(),
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBar(double expandedW) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      width: _isExpanded ? expandedW : kIslandCompactW,
      height: _isExpanded ? kIslandExpandedH : kIslandCompactH,
      child: CustomPaint(
        painter: IslandShapePainter(expanded: _isExpanded),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (_isExpanded)
               AnimatedBuilder(
                  animation: Listenable.merge([_siriCtrl, _siriIntensityCtrl]),
                  builder: (_, __) => CustomPaint(
                    painter: SiriHaloPainter(radius: 20, rotation: _siriCtrl.value * 2 * math.pi, intensity: _siriIntensityCtrl.value),
                    child: Container(),
                  ),
                ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 200),
              crossFadeState: _isExpanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
              firstChild: _buildCompactContent(),
              secondChild: _buildExpandedContent(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCompactContent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          winLogo(size: 16, pulse: _pulseCtrl),
          Text(_clockText, style: const TextStyle(fontWeight: FontWeight.bold)),
          const Icon(Icons.battery_full, size: 16, color: Colors.white),
        ],
      ),
    );
  }

  Widget _buildExpandedContent() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _iconBtn(Icons.search_rounded, IslandPanel.search, color: Sys.blue),
              const SizedBox(width: 8),
              _iconBtn(Icons.apps_rounded, IslandPanel.apps),
              const SizedBox(width: 8),
              _iconBtn(Icons.music_note_rounded, IslandPanel.media)
            ],
          ),
          Expanded(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  winLogo(size: 20),
                  const SizedBox(width: 8),
                  Text(_clockText, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _iconBtn(Icons.wifi_rounded, IslandPanel.wifi, active: _wifiEnabled, color: Sys.blue),
              const SizedBox(width: 8),
              _iconBtn(Icons.bluetooth_rounded, IslandPanel.bluetooth, active: _bluetoothEnabled, color: Sys.blue),
              const SizedBox(width: 8),
              // Was Icons.volume_up_rounded — swapped for the settings icon.
              _iconBtn(Icons.settings_rounded, IslandPanel.volume),
              const SizedBox(width: 8),
              _iconBtn(Icons.battery_charging_full_rounded, IslandPanel.battery, color: Sys.green),
            ],
          ),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, IslandPanel panel, {bool? active, Color color = Colors.white}) {
    final isActive = _activePanel == panel;
    return GlassChip(
      active: isActive,
      onTap: () => _openPanel(panel),
      child: Icon(icon, size: 16, color: active == false ? Colors.grey : (isActive ? color : Colors.white)),
    );
  }

  Widget _buildPanelBody() {
    switch (_activePanel) {
      case IslandPanel.wifi: return _wifiPanel();
      case IslandPanel.volume: return _volumePanel();
      case IslandPanel.battery: return _batteryPanel();
      case IslandPanel.apps: return _appsPanel();
      case IslandPanel.media: return _mediaPanel();
      case IslandPanel.search: return _searchPanel();
      case IslandPanel.bluetooth: return _bluetoothPanel();
      default: return const SizedBox.shrink();
    }
  }

  Widget _wifiPanel() {
    final connected = _wifiEnabled && _wifiSSID.isNotEmpty;
    final others = _wifiNetworks.where((n) => n['ssid'] != _wifiSSID).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Wi-Fi", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_wifiEnabled)
                  GestureDetector(
                    onTap: _scanningWifi ? null : _fetchWifiNetworks,
                    child: _scanningWifi
                        ? const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
                            ),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18, color: Colors.grey),
                  ),
                const SizedBox(width: 12),
                GlassToggle(value: _wifiEnabled, onChanged: (v) => _toggleWifi()),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (!_wifiEnabled)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text("Wi-Fi interface is turned off.", style: TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else ...[
          if (connected)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.wifi_rounded, color: Sys.blue),
              title: Text(_wifiSSID, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              subtitle: const Text("Connected", style: TextStyle(fontSize: 11, color: Colors.grey)),
              trailing: const Icon(Icons.check_rounded, color: Sys.blue, size: 16),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text("Not connected", style: TextStyle(color: Colors.grey, fontSize: 12)),
            ),
          const Padding(
            padding: EdgeInsets.only(top: 8, bottom: 6),
            child: Text("AVAILABLE NETWORKS", style: TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: others.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      _scanningWifi ? "Scanning..." : "No networks found.",
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: others.length,
                    itemBuilder: (context, i) => _wifiNetworkRow(others[i]),
                  ),
          ),
        ],
      ],
    );
  }

  Widget _wifiNetworkRow(Map<String, dynamic> net) {
    final ssid = net['ssid'] as String? ?? "";
    final secured = net['secured'] == true;
    final saved = net['saved'] == true;
    final busy = _connectingSsid == ssid;

    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.wifi_rounded, size: 18, color: Colors.white70),
        title: Text(ssid, style: const TextStyle(fontSize: 13)),
        subtitle: saved ? const Text("Saved", style: TextStyle(fontSize: 10.5, color: Colors.grey)) : null,
        trailing: busy
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Sys.blue),
              )
            : secured
                ? const Icon(Icons.lock_rounded, size: 14, color: Colors.grey)
                : null,
        onTap: busy ? null : () => _onTapNetwork(net),
      ),
    );
  }

  Widget _bluetoothPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Bluetooth", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_bluetoothEnabled)
                  GestureDetector(
                    onTap: _scanningBluetooth ? null : _fetchBluetoothDevices,
                    child: _scanningBluetooth
                        ? const Padding(
                            padding: EdgeInsets.only(right: 4),
                            child: SizedBox(
                              width: 14, height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
                            ),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18, color: Colors.grey),
                  ),
                const SizedBox(width: 12),
                GlassToggle(value: _bluetoothEnabled, onChanged: (v) => _toggleBluetooth()),
              ],
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (!_bluetoothEnabled)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text("Bluetooth is disabled.", style: TextStyle(color: Colors.grey, fontSize: 13)),
          )
        else ...[
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text("PAIRED DEVICES", style: TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: _bluetoothDevices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      _scanningBluetooth ? "Scanning..." : "No paired devices found.",
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: _bluetoothDevices.length,
                    itemBuilder: (context, i) => _bluetoothDeviceRow(_bluetoothDevices[i]),
                  ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("NEARBY DEVICES", style: TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
              GestureDetector(
                onTap: _scanningNearby ? null : _scanNearbyBluetooth,
                child: _scanningNearby
                    ? const Padding(
                        padding: EdgeInsets.only(right: 2),
                        child: SizedBox(
                          width: 12, height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.grey),
                        ),
                      )
                    : const Text("Scan", style: TextStyle(color: Sys.blue, fontSize: 11, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 150),
            child: _nearbyBluetoothDevices.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      _scanningNearby ? "Scanning nearby (~10s)..." : "Tap Scan to find nearby devices.",
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: _nearbyBluetoothDevices.length,
                    itemBuilder: (context, i) => _nearbyDeviceRow(_nearbyBluetoothDevices[i]),
                  ),
          ),
        ],
      ],
    );
  }

  Widget _nearbyDeviceRow(Map<String, dynamic> device) {
    final name = device['name'] as String? ?? "Unknown Device";
    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.bluetooth_searching_rounded, size: 18, color: Colors.white70),
        title: Text(name, style: const TextStyle(fontSize: 13)),
        trailing: const Icon(Icons.chevron_right_rounded, size: 16, color: Colors.grey),
        onTap: () => _pairBluetoothDevice(name),
      ),
    );
  }

  Widget _bluetoothDeviceRow(Map<String, dynamic> device) {
    final name = device['name'] as String? ?? "Unknown Device";
    final connected = device['connected'] == true;
    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.bluetooth_rounded, size: 18, color: connected ? Sys.blue : Colors.white70),
        title: Text(name, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          connected ? "Connected" : "Paired",
          style: TextStyle(fontSize: 10.5, color: connected ? Sys.blue : Colors.grey),
        ),
        trailing: connected ? const Icon(Icons.check_rounded, color: Sys.blue, size: 16) : null,
      ),
    );
  }

  Widget _volumePanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text("Sound & Interface Displays", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Row(children: [
          const Icon(Icons.volume_up, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Slider(
            value: _volume, min: 0, max: 100, activeColor: Sys.blue,
            onChanged: (v) => setState(() => _volume = v),
            onChangeEnd: (v) async {
              await http.post(Uri.parse('http://127.0.0.1:8000/api/volume/set'),
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({"value": v.toInt()})
              );
            },
          )),
        ]),
        Row(children: [
          const Icon(Icons.brightness_6, size: 18, color: Colors.grey),
          const SizedBox(width: 8),
          Expanded(child: Slider(
            value: _brightness, min: 0, max: 100, activeColor: Sys.orange,
            onChanged: (v) => setState(() => _brightness = v),
            onChangeEnd: (v) async {
              await http.post(Uri.parse('http://127.0.0.1:8000/api/brightness/set'),
                headers: {"Content-Type": "application/json"},
                body: jsonEncode({"value": v.toInt()})
              );
            },
          )),
        ]),
        const SizedBox(height: 14),
        const Text("OUTPUT DEVICE", style: TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
        const SizedBox(height: 6),
        _buildAudioDeviceList(),
      ],
    );
  }

  Widget _buildAudioDeviceList() {
    if (!_audioModuleInstalled) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text(
          "Install the AudioDeviceCmdlets PowerShell module to switch output devices "
          "(Install-Module -Name AudioDeviceCmdlets -Scope CurrentUser).",
          style: TextStyle(color: Colors.grey, fontSize: 11.5, height: 1.4),
        ),
      );
    }
    if (_loadingAudioDevices && _audioOutputDevices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text("Loading devices...", style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    if (_audioOutputDevices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text("No output devices found.", style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: ListView.builder(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _audioOutputDevices.length,
        itemBuilder: (context, i) => _audioDeviceRow(_audioOutputDevices[i]),
      ),
    );
  }

  Widget _audioDeviceRow(Map<String, dynamic> device) {
    final name = device['name'] as String? ?? "Unknown Device";
    final index = device['index'] as int?;
    final isDefault = device['default'] == true;
    final busy = _switchingAudioDeviceIndex == index;

    IconData icon = Icons.speaker_rounded;
    final n = name.toLowerCase();
    if (n.contains('headphone') || n.contains('headset') || n.contains('earbud') || n.contains('buds')) {
      icon = Icons.headphones_rounded;
    } else if (n.contains('bluetooth')) {
      icon = Icons.bluetooth_audio_rounded;
    } else if (n.contains('hdmi') || n.contains('display') || n.contains('monitor')) {
      icon = Icons.tv_rounded;
    }

    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 18, color: isDefault ? Sys.blue : Colors.white70),
        title: Text(name, style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
        trailing: busy
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Sys.blue),
              )
            : isDefault
                ? const Icon(Icons.check_rounded, color: Sys.blue, size: 16)
                : null,
        onTap: (busy || isDefault || index == null) ? null : () => _switchAudioDevice(index),
      ),
    );
  }

  Widget _batteryPanel() {
    final status = _batteryStatus;
    final plugged = status?['plugged'] == true;
    final timeText = status?['time_text'] as String?;
    final noBattery = status != null && status['available'] == false;

    final icon = noBattery
        ? Icons.power_rounded
        : (plugged ? Icons.battery_charging_full_rounded : Icons.battery_std_rounded);
    final iconColor = plugged ? Sys.green : (_batteryPercent <= 20 ? Sys.red : Colors.white);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 44, color: iconColor),
        const SizedBox(height: 8),
        Text(
          noBattery ? "Plugged In" : "$_batteryPercent%",
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        Text(
          noBattery
              ? "No battery detected (desktop)"
              : (timeText ?? (plugged ? "Plugged In" : "On Battery")),
          style: const TextStyle(color: Colors.grey, fontSize: 12),
        ),
        if (!noBattery) ...[
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _batteryPercent / 100,
              minHeight: 6,
              backgroundColor: Glass.fillSubtle,
              color: plugged ? Sys.green : (_batteryPercent <= 20 ? Sys.red : Sys.green),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            "POWER PLAN",
            style: TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8),
          ),
        ),
        const SizedBox(height: 6),
        _buildPowerPlanList(),
      ],
    );
  }

  Widget _buildPowerPlanList() {
    if (_loadingPowerPlans && _powerPlans.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text("Loading power plans...", style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    if (_powerPlans.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 6),
        child: Text("No power plans found.", style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    return Column(
      children: _powerPlans.map((plan) => _powerPlanRow(plan)).toList(),
    );
  }

  Widget _powerPlanRow(Map<String, dynamic> plan) {
    final guid = plan['guid'] as String? ?? "";
    final name = plan['name'] as String? ?? "Unknown Plan";
    final active = plan['active'] == true;
    final busy = _switchingPlanGuid == guid;

    IconData icon = Icons.balance_rounded;
    final n = name.toLowerCase();
    if (n.contains('saver')) icon = Icons.eco_rounded;
    if (n.contains('high') || n.contains('ultimate') || n.contains('performance')) icon = Icons.bolt_rounded;

    return Material(
      color: Colors.transparent,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, size: 18, color: active ? Sys.blue : Colors.white70),
        title: Text(name, style: const TextStyle(fontSize: 13)),
        trailing: busy
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Sys.blue),
              )
            : active
                ? const Icon(Icons.check_rounded, color: Sys.blue, size: 16)
                : null,
        onTap: (busy || active || guid.isEmpty) ? null : () => _switchPowerPlan(guid),
      ),
    );
  }

  IconData _iconForApp(String name, String type) {
    if (type == 'action') return Icons.flash_on_rounded;
    final n = name.toLowerCase();
    if (n.contains('explorer') || n.contains('file')) return Icons.folder_rounded;
    if (n.contains('terminal') || n.contains('cmd') || n.contains('powershell')) return Icons.terminal_rounded;
    if (n.contains('task manager')) return Icons.developer_board_rounded;
    if (n.contains('notepad') || n.contains('text')) return Icons.description_rounded;
    if (n.contains('chrome') || n.contains('edge') || n.contains('firefox') || n.contains('browser')) return Icons.public_rounded;
    if (n.contains('code') || n.contains('studio')) return Icons.code_rounded;
    if (n.contains('spotify') || n.contains('music')) return Icons.music_note_rounded;
    if (n.contains('discord') || n.contains('slack') || n.contains('teams')) return Icons.forum_rounded;
    if (n.contains('mail') || n.contains('outlook')) return Icons.mail_rounded;
    if (n.contains('calculator')) return Icons.calculate_rounded;
    if (n.contains('settings') || n.contains('control panel')) return Icons.settings_rounded;
    if (n.contains('photo') || n.contains('paint') || n.contains('image')) return Icons.image_rounded;
    if (n.contains('word')) return Icons.article_rounded;
    if (n.contains('excel') || n.contains('sheet')) return Icons.grid_on_rounded;
    if (n.contains('powerpoint') || n.contains('slides')) return Icons.slideshow_rounded;
    if (n.contains('steam') || n.contains('game')) return Icons.sports_esports_rounded;
    if (n.contains('zoom') || n.contains('meet')) return Icons.videocam_rounded;
    if (n.contains('store')) return Icons.storefront_rounded;
    return Icons.apps_rounded;
  }

  Widget _appsPanel() {
    final systemActions = [
      {'id': 'screenshot', 'name': 'Screenshot', 'icon': Icons.screenshot_monitor_rounded, 'color': Sys.teal},
      {'id': 'lock', 'name': 'Lock', 'icon': Icons.lock_rounded, 'color': Sys.indigo},
      {
        'id': 'darkmode',
        'name': _darkModeOn ? 'Dark Mode' : 'Light Mode',
        'icon': _darkModeOn ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
        'color': _darkModeOn ? Sys.purple : Sys.yellow,
      },
      {'id': 'sleep', 'name': 'Sleep', 'icon': Icons.bedtime_rounded, 'color': Sys.blue},
      {'id': 'restart', 'name': 'Restart', 'icon': Icons.restart_alt_rounded, 'color': Sys.orange},
      {'id': 'shutdown', 'name': 'Shut Down', 'icon': Icons.power_settings_new_rounded, 'color': Sys.red},
    ];

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("System", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 14,
          children: systemActions.map((a) {
            final id = a['id'] as String;
            final pending = _pendingConfirmAction == id;
            return _quickTile(
              icon: a['icon'] as IconData,
              label: pending ? 'Confirm?' : a['name'] as String,
              color: pending ? Sys.red : a['color'] as Color,
              onTap: () => id == 'darkmode' ? _toggleDarkMode() : _handleSystemAction(id),
            );
          }).toList(),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text("Pinned Apps", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            GestureDetector(
              onTap: () => setState(() {
                _editingQuickActions = !_editingQuickActions;
                _addingAction = false;
              }),
              child: Text(
                _editingQuickActions ? "Done" : "Edit",
                style: const TextStyle(color: Sys.blue, fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 14,
          children: [
            ..._quickActions.map((a) => Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _quickTile(
                      icon: _iconForApp(a['name'], a['type']),
                      label: a['name'],
                      color: Sys.teal,
                      onTap: _editingQuickActions ? null : () => _launchQuickAction(a),
                    ),
                    if (_editingQuickActions)
                      Positioned(
                        top: -6,
                        right: -6,
                        child: GestureDetector(
                          onTap: () => _removeQuickAction(a['name']),
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: const BoxDecoration(color: Sys.red, shape: BoxShape.circle),
                            child: const Icon(Icons.remove_rounded, size: 13, color: Colors.white),
                          ),
                        ),
                      ),
                  ],
                )),
            if (!_editingQuickActions)
              _quickTile(
                icon: Icons.add_rounded,
                label: 'Add',
                color: Colors.grey,
                dashed: true,
                onTap: () => setState(() => _addingAction = !_addingAction),
              ),
          ],
        ),
        if (_addingAction) ...[
          const SizedBox(height: 14),
          _buildAddActionSearch(),
        ],
      ],
    );
  }

  Widget _quickTile({
    required IconData icon,
    required String label,
    required Color color,
    VoidCallback? onTap,
    bool dashed = false,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color.withOpacity(0.16),
              borderRadius: BorderRadius.circular(14),
              border: dashed ? Border.all(color: Colors.white24, width: 1) : null,
            ),
            child: Icon(icon, size: 24, color: color),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: 60,
            child: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddActionSearch() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _addActionController,
                autofocus: true,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: "Search apps to pin...",
                  hintStyle: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 13),
                  filled: true,
                  fillColor: Glass.fillSubtle,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  isDense: true,
                ),
                onChanged: _searchForAdd,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18, color: Colors.grey),
              onPressed: () => setState(() {
                _addingAction = false;
                _addActionResults = [];
                _addActionController.clear();
              }),
            ),
          ],
        ),
        if (_addActionResults.isNotEmpty)
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: _addActionResults.length,
              itemBuilder: (context, i) {
                final item = _addActionResults[i];
                return Material(
                  color: Colors.transparent,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      _iconForApp(item['name'], item['type'] == 'Action' ? 'action' : 'app'),
                      size: 16,
                      color: Sys.teal,
                    ),
                    title: Text(item['name'], style: const TextStyle(fontSize: 12.5)),
                    onTap: () => _addQuickAction(item),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _mediaPanel() {
    final np = _nowPlaying;
    final title = (np?['title'] as String? ?? "").trim();
    final artist = (np?['artist'] as String? ?? "").trim();
    final app = (np?['app'] as String? ?? "").trim();
    final status = (np?['status'] as String? ?? "").trim();
    final hasTrack = title.isNotEmpty;
    final isPlaying = status == 'playing';

    final subtitle = hasTrack
        ? (artist.isNotEmpty ? artist : (app.isNotEmpty ? app : ""))
        : "No Track Streaming Currently";

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          height: 100, width: double.infinity,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Sys.purple.withOpacity(0.15)),
          child: Icon(Icons.music_note, size: 44, color: Sys.purple.withOpacity(hasTrack ? 1.0 : 0.5)),
        ),
        const SizedBox(height: 10),
        Text(
          hasTrack ? title : "Nothing Playing",
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          subtitle,
          style: const TextStyle(color: Colors.grey, fontSize: 11),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.skip_previous, size: 20),
              onPressed: hasTrack ? _mediaPrevious : null,
              color: hasTrack ? Colors.white : Colors.grey,
            ),
            IconButton(
              icon: Icon(isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, size: 36),
              onPressed: hasTrack ? _mediaTogglePlayPause : null,
              color: hasTrack ? Colors.white : Colors.grey,
            ),
            IconButton(
              icon: const Icon(Icons.skip_next, size: 20),
              onPressed: hasTrack ? _mediaNext : null,
              color: hasTrack ? Colors.white : Colors.grey,
            ),
          ],
        )
      ],
    );
  }

  // ── Mac Spotlight-style search panel ─────────────────────────────
  Widget _searchPanel() {
    final items = _spotlightItems();
    final hasQuery = _searchQuery.trim().isNotEmpty;
    final appCount = _discoveredApps.length;

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          setState(() => _selectedIndex = (_selectedIndex + 1).clamp(0, items.length - 1));
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          setState(() => _selectedIndex = (_selectedIndex - 1).clamp(0, items.length - 1));
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.enter) {
          _runSelected();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          _siriField.clear();
          setState(() => _searchQuery = "");
          _scheduleHide();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.search_rounded, color: Colors.white70, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _siriField,
                  focusNode: _searchFieldFocus,
                  autofocus: true,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w400),
                  decoration: InputDecoration(
                    hintText: "Spotlight Search",
                    hintStyle: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 20),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onChanged: (value) {
                    setState(() => _searchQuery = value);
                    _fetchBackendResults(value);
                  },
                  onSubmitted: (_) => _runSelected(),
                ),
              ),
            ],
          ),
          if (hasQuery) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Divider(height: 1, color: Glass.borderSubtle),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (appCount > 0) ...[
                      _sectionLabel(appCount == 1 ? "TOP HIT" : "APPLICATIONS"),
                      ...List.generate(appCount, (i) => _buildSpotlightRow(
                        item: items[i],
                        index: i,
                        selected: i == _selectedIndex,
                        big: appCount == 1 && i == 0,
                      )),
                      const SizedBox(height: 8),
                    ],
                    _sectionLabel("SEARCH WEB"),
                    _buildSpotlightRow(
                      item: items.last,
                      index: items.length - 1,
                      selected: items.length - 1 == _selectedIndex,
                      big: false,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6, top: 2),
      child: Text(text, style: const TextStyle(color: Colors.grey, fontSize: 10, fontWeight: FontWeight.bold, letterSpacing: 0.8)),
    );
  }

  Widget _buildSpotlightRow({
    required Map<String, dynamic> item,
    required int index,
    required bool selected,
    required bool big,
  }) {
    final bool isWeb = item['isWeb'] == true;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() => _selectedIndex = index);
        _runSelected();
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _selectedIndex = index),
        cursor: SystemMouseCursors.click,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          margin: const EdgeInsets.symmetric(vertical: 2),
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: big ? 12 : 8),
          decoration: BoxDecoration(
            color: selected ? Sys.blue.withOpacity(0.9) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Container(
                width: big ? 40 : 28,
                height: big ? 40 : 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: isWeb
                      ? Sys.orange.withOpacity(selected ? 0.25 : 0.15)
                      : Colors.white.withOpacity(selected ? 0.2 : 0.08),
                  borderRadius: BorderRadius.circular(big ? 10 : 7),
                ),
                child: Icon(item['icon'] as IconData, size: big ? 22 : 15, color: isWeb ? Sys.orange : Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  item['name'],
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: big ? 16 : 13.5,
                    fontWeight: big ? FontWeight.w600 : FontWeight.w500,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                item['type'],
                style: TextStyle(color: Colors.white.withOpacity(selected ? 0.8 : 0.4), fontSize: 10.5, fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}