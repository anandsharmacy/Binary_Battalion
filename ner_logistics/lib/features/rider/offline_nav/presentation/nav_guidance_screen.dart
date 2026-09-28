import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../../../../core/platform/device_channel.dart';
import '../../../../mock_data/models.dart';
import '../../../../services/routing/osrm_models.dart';
import '../../../../services/routing/trip_plan.dart';
import '../../../../shared/map/ner_map.dart';
import '../../../../shared/widgets/glass_surface.dart';
import '../../../../theme/colors.dart';
import '../../../../theme/text_styles.dart';
import '../../application/rider_tracking_controller.dart';
import '../application/nav_session.dart';
import '../data/road_graph.dart';
import 'offline_nav_page.dart';

/// Full-screen turn-by-turn guidance over an offline route.
class NavGuidanceScreen extends ConsumerStatefulWidget {
  final OsrmRoute route;
  final NavDestination destination;
  final String graphPath;

  /// Tests inject fixes; the app uses the device GPS.
  final Stream<Position>? positions;

  const NavGuidanceScreen({
    super.key,
    required this.route,
    required this.destination,
    required this.graphPath,
    this.positions,
  });

  @override
  ConsumerState<NavGuidanceScreen> createState() => _NavGuidanceScreenState();
}

class _NavGuidanceScreenState extends ConsumerState<NavGuidanceScreen> {
  final _map = MapController();
  late final NavSession _nav;
  FlutterTts? _tts;
  bool _voice = true;
  bool _follow = true;
  String? _gpsError;
  late final RiderTrackingController _tracker;

  @override
  void initState() {
    super.initState();
    _tracker = ref.read(riderTrackingProvider.notifier);
    _nav = NavSession(
      route: widget.route,
      destination: widget.destination.point,
      destinationName: widget.destination.name,
      reroute: (from, heading) => routeOffline(
        widget.graphPath,
        from,
        widget.destination.point,
        headingDeg: heading,
      ),
      onCue: _cue,
    )..addListener(_onNav);
    unawaited(_begin());
  }

  Future<void> _begin() async {
    unawaited(DeviceChannel.keepScreenOn(true));
    if (widget.positions != null) {
      _nav.listen(widget.positions!);
      return;
    }
    await _setupVoice();
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        throw 'Location permission is off. Allow it in Settings to get turn-by-turn guidance.';
      }
      // Geolocator shares one platform stream and the first subscriber's
      // settings win: have the tracker (if sharing) restart it at nav rate.
      final sharing = ref.read(riderTrackingProvider).isSharing;
      await _tracker.setNavigating(true);
      if (!mounted) return;
      _nav.listen(
        Geolocator.getPositionStream(
          locationSettings: navigationLocationSettings(foreground: sharing),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _gpsError = '$e');
    }
  }

  Future<void> _setupVoice() async {
    try {
      final tts = FlutterTts();
      await tts.awaitSpeakCompletion(true);
      final inAvailable = await tts.isLanguageAvailable('en-IN') == true;
      await tts.setLanguage(inAvailable ? 'en-IN' : 'en-US');
      if (!kIsWeb && Platform.isIOS) {
        // Plays with the ring/silent switch on and ducks music (HIG: audio).
        await tts.setSharedInstance(true);
        await tts.setIosAudioCategory(IosTextToSpeechAudioCategory.playback, [
          IosTextToSpeechAudioCategoryOptions.duckOthers,
          IosTextToSpeechAudioCategoryOptions
              .interruptSpokenAudioAndMixWithOthers,
        ], IosTextToSpeechAudioMode.voicePrompt);
      }
      _tts = tts;
      if (!kIsWeb && Platform.isAndroid) unawaited(_checkOfflineVoice(tts));
    } catch (e) {
      debugPrint('TTS unavailable: $e');
    }
  }

  /// Android voices can need the network; say so once instead of going quiet.
  Future<void> _checkOfflineVoice(FlutterTts tts) async {
    final voices = (await tts.getVoices as List?)?.cast<Map>() ?? const [];
    final offline = voices.any(
      (v) =>
          '${v['locale']}'.startsWith('en') &&
          '${v['network_required']}' != '1',
    );
    if (!offline && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Voice needs offline speech data: Settings › System › Languages › Text-to-speech.',
          ),
        ),
      );
    }
  }

  void _cue(String text, {bool urgent = false}) {
    if (urgent) HapticFeedback.mediumImpact();
    if (_voice && _tts != null) {
      unawaited(_tts!.speak(text));
    } else if (mounted) {
      // After the frame: cues can arrive while the screen is still building.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(
            SemanticsService.sendAnnouncement(
              View.of(context),
              text,
              TextDirection.ltr,
            ),
          );
        }
      });
    }
  }

  void _onNav() {
    final p = _nav.position;
    if (_follow && p != null && mounted) {
      try {
        _map.move(p, 16);
      } catch (_) {
        // Map not laid out yet; the next fix moves it.
      }
    }
    if (_nav.status == NavStatus.arrived) unawaited(_release());
    if (mounted) setState(() {});
  }

  bool _released = false;
  Future<void> _release() async {
    if (_released) return;
    _released = true;
    await _nav.stop();
    unawaited(_tts?.stop());
    unawaited(DeviceChannel.keepScreenOn(false));
    await _tracker.setNavigating(false);
  }

  @override
  void dispose() {
    unawaited(_release());
    _nav
      ..removeListener(_onNav)
      ..dispose();
    _map.dispose();
    super.dispose();
  }

  Future<void> _confirmEnd() async {
    // HIG Action sheets: destructive choice first, Cancel last.
    final end = await showModalBottomSheet<bool>(
      context: context,
      showDragHandle: true,
      builder: (context) => GlassSurface(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'End this route?',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.bodySmallMedium,
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 50),
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.signalRed700,
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('End Route'),
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 50),
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (end == true && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final nav = _nav;
    final r = nav.route;
    final p = nav.position;
    final arrived = nav.status == NavStatus.arrived;
    return PopScope(
      canPop: arrived,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmEnd();
      },
      child: Scaffold(
        backgroundColor: AppColors.paper,
        body: Stack(
          children: [
            Positioned.fill(
              child: MergeSemantics(
                child: Semantics(
                  label: 'Navigation map',
                  child: NerMap(
                    mapController: _map,
                    fitPoints: [?p, if (p == null) ...r.geometry.take(2)],
                    maxFitZoom: 17,
                    offlineMode: true,
                    showOfflineBadge: false,
                    showRouteLabels: false,
                    attributionBottom: 120,
                    onMapGesture: () {
                      if (_follow) setState(() => _follow = false);
                    },
                    routes: [
                      if (nav.previousRoute != null)
                        MapRoute(
                          points: nav.previousRoute!.geometry,
                          tone: MapLineTone.avoided,
                        ),
                      // Dashed link to the route while the rider isn't on it yet.
                      if (p != null && nav.offsetM > NavSession.offRouteMinM)
                        MapRoute(
                          points: [p, r.pointAtM(nav.alongM)],
                          tone: MapLineTone.candidate,
                        ),
                      if (nav.status != NavStatus.rerouting) ...[
                        MapRoute(
                          points: r.sliceM(0, nav.alongM),
                          tone: MapLineTone.travelled,
                        ),
                        MapRoute(
                          points: r.sliceM(nav.alongM, r.geometryLengthM),
                          tone: MapLineTone.clear,
                        ),
                      ],
                    ],
                    vehicles: [
                      if (p != null)
                        MapVehicle(
                          id: 'me',
                          point: p,
                          risk: Priority.low,
                          label: 'Your location',
                          live: true,
                          heading: nav.heading,
                        ),
                    ],
                    pois: [
                      MapPoi(
                        point: widget.destination.point,
                        kind: MapPoiKind.destination,
                        label: widget.destination.name,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!arrived) _ManeuverBanner(nav: nav),
                    if (_gpsError != null)
                      _Chip(text: _gpsError!, color: AppColors.signalRed700),
                    if (p == null && _gpsError == null && !arrived)
                      const _Chip(
                        text: 'Waiting for GPS…',
                        color: AppColors.navy900,
                      ),
                    if (nav.weakGps)
                      const _Chip(
                        text: 'Weak GPS signal',
                        color: AppColors.saffronDark,
                      ),
                    if (nav.rerouteError != null &&
                        nav.status == NavStatus.guiding)
                      _Chip(
                        text: nav.rerouteError!,
                        color: AppColors.signalRed700,
                      ),
                  ],
                ),
              ),
            ),
            if (!_follow && !arrived)
              Positioned(
                left: 12,
                bottom: 130,
                child: SafeArea(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.navy900,
                    ),
                    onPressed: () {
                      setState(() => _follow = true);
                      _onNav();
                    },
                    icon: const Icon(Icons.navigation),
                    label: const Text('Re-center'),
                  ),
                ),
              ),
            Align(
              alignment: Alignment.bottomCenter,
              child: arrived ? _arrivalCard() : _bottomBar(nav),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(NavSession nav) {
    final eta = DateFormat.Hm().format(nav.eta);
    final left = formatDuration(Duration(seconds: nav.remainingS.round()));
    final dist = formatDistance(nav.remainingM);
    return Material(
      color: Colors.white,
      elevation: 8,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  label: 'Arrive at $eta, $left and $dist remaining',
                  excludeSemantics: true,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        eta,
                        style: AppTextStyles.sectionHeading.copyWith(
                          color: AppColors.deepGreen700,
                        ),
                      ),
                      Text('$left · $dist', style: AppTextStyles.bodySmall),
                    ],
                  ),
                ),
              ),
              IconButton(
                tooltip: _voice
                    ? 'Mute voice guidance'
                    : 'Unmute voice guidance',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                icon: Icon(
                  _voice ? Icons.volume_up : Icons.volume_off,
                  color: AppColors.navy900,
                ),
                onPressed: () {
                  setState(() => _voice = !_voice);
                  if (!_voice) unawaited(_tts?.stop());
                },
              ),
              const SizedBox(width: 4),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.signalRed700,
                  minimumSize: const Size(72, 48),
                ),
                onPressed: _confirmEnd,
                child: const Text('End'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _arrivalCard() {
    return GlassSurface(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Icon(Icons.flag, color: AppColors.deepGreen700, size: 32),
              const SizedBox(height: 8),
              Semantics(
                header: true,
                liveRegion: true,
                child: Text(
                  'You’ve arrived at ${widget.destination.name}',
                  textAlign: TextAlign.center,
                  style: AppTextStyles.sectionHeading,
                ),
              ),
              const SizedBox(height: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 50),
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Navy, high-contrast next-manoeuvre banner.
class _ManeuverBanner extends StatelessWidget {
  final NavSession nav;
  const _ManeuverBanner({required this.nav});

  @override
  Widget build(BuildContext context) {
    final rerouting = nav.status == NavStatus.rerouting;
    final n = nav.next;
    final step =
        n?.step ?? (nav.route.steps.isEmpty ? null : nav.route.steps.last);
    final distance = n == null ? '' : formatDistance(n.inM);
    final instruction = rerouting
        ? 'Rerouting…'
        : step?.instruction ?? 'Follow the route';
    // "Then …" when the following manoeuvre comes right after this one.
    OsrmStep? then;
    if (n != null && !rerouting) {
      final i = nav.route.steps.indexOf(n.step);
      if (i >= 0 && i + 1 < nav.route.steps.length && n.step.distanceM < 300) {
        then = nav.route.steps[i + 1];
      }
    }
    return Semantics(
      liveRegion: true,
      label: rerouting ? 'Rerouting' : '$distance, $instruction',
      excludeSemantics: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.navy900,
          borderRadius: BorderRadius.circular(14),
          boxShadow: const [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                SizedBox(
                  width: 48,
                  height: 48,
                  child: rerouting
                      ? const Padding(
                          padding: EdgeInsets.all(10),
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 3,
                          ),
                        )
                      : Icon(maneuverIcon(step), color: Colors.white, size: 44),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (distance.isNotEmpty && !rerouting)
                        Text(
                          distance,
                          style: AppTextStyles.pageHeading.copyWith(
                            color: Colors.white,
                          ),
                        ),
                      Text(
                        instruction,
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (then != null) ...[
              const Divider(color: Colors.white24, height: 16),
              Row(
                children: [
                  Text(
                    'Then',
                    style: AppTextStyles.bodySmall.copyWith(
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(maneuverIcon(then), color: Colors.white, size: 22),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

IconData maneuverIcon(OsrmStep? s) {
  if (s == null) return Icons.straight;
  if (s.type == 'arrive') return Icons.flag;
  if (s.type.startsWith('roundabout') || s.type == 'rotary') {
    return Icons.roundabout_right;
  }
  return switch (s.modifier) {
    'right' => Icons.turn_right,
    'left' => Icons.turn_left,
    'slight right' => Icons.turn_slight_right,
    'slight left' => Icons.turn_slight_left,
    'sharp right' => Icons.turn_sharp_right,
    'sharp left' => Icons.turn_sharp_left,
    'uturn' => Icons.u_turn_left,
    _ => Icons.straight,
  };
}

class _Chip extends StatelessWidget {
  final String text;
  final Color color;
  const _Chip({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: AppTextStyles.captionSemibold.copyWith(color: Colors.white),
        ),
      ),
    );
  }
}
