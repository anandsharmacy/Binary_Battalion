import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import '../chat/chat_sheet.dart';
import '../../core/network/connectivity_provider.dart';
import '../../mock_data/mock_officers.dart';
import '../../mock_data/mock_repository.dart';
import '../../mock_data/models.dart';
import '../../shared/motion.dart';
import '../../shared/widgets/app_header.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/offline_banner.dart';
import '../../features/profile/profile_sheet.dart';
import '../alerts/push_navigation.dart';
import '../../theme/colors.dart';
import '../ml/application/ml_providers.dart';
import '../auth/application/auth_controller.dart';
import 'application/rider_tracking_controller.dart';
import 'data/rider_repository.dart';
import 'domain/rider_context.dart';
import 'logistics/application/rider_logistics_service.dart';
import 'rider_dashboard.dart';
import 'rider_drawer.dart';

/// RiderShell — top-level widget for the Logistics Rider track.
///
/// Identity comes from Supabase Auth (`currentProfileProvider`), vehicle and
/// assigned shipments from `get_my_rider_context`, and live location sharing
/// from [riderTrackingProvider]. Trip actions update the in-app state and
/// also drive the real tracker: Start → share, Pause → low power,
/// Resume → share, Arrived → low power. Assignments come from the officers
/// (accept / decline / start / arrive / complete go through database RPCs).
class RiderShell extends ConsumerStatefulWidget {
  final VoidCallback onSignOut;

  const RiderShell({super.key, required this.onSignOut});

  @override
  ConsumerState<RiderShell> createState() => _RiderShellState();
}

class _RiderShellState extends ConsumerState<RiderShell> {
  RiderNav _nav = RiderNav.dashboard;
  bool _drawerOpen = false;
  bool _profileOpen = false;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // Live changes arrive through riderShipmentSyncProvider. This timer is the
    // safety net for the one change that produces no event for this rider: a
    // shipment reassigned to someone else.
    _refresh = Timer.periodic(const Duration(seconds: 45), (_) {
      if (mounted) ref.invalidate(riderContextProvider);
    });
    // The rider tapped a "new shipment" push notification (app was
    // backgrounded or terminated): jump to Deliveries so they can respond.
    riderShipmentTapSignal.addListener(_onShipmentTap);
  }

  void _onShipmentTap() {
    if (mounted) setState(() => _nav = RiderNav.deliveries);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    riderShipmentTapSignal.removeListener(_onShipmentTap);
    super.dispose();
  }

  String get _title => switch (_nav) {
        RiderNav.dashboard => 'Rider Dashboard',
        RiderNav.deliveries => 'My Deliveries',
        RiderNav.trip => 'Active Trip',
        RiderNav.offlineNav => 'Offline Navigation',
        RiderNav.routeAlerts => 'Route & Alerts',
        RiderNav.report => 'Report Issue',
        RiderNav.history => 'Delivery History',
        RiderNav.queue => 'Offline Queue',
      };

  String _subtitle(Officer officer, RiderContext? ctx, RiderTrackingState tracking) => switch (_nav) {
        RiderNav.dashboard => '${officer.name} · ${ctx?.vehicleRegistration ?? 'vehicle not set'}',
        RiderNav.deliveries => '${ctx?.shipments.length ?? 0} assignment${ctx?.shipments.length == 1 ? '' : 's'} · ${officer.region}',
        RiderNav.trip => _tripSubtitle(tracking),
        RiderNav.offlineNav => 'Routes and voice guidance without signal',
        RiderNav.routeAlerts => 'Route safety · live advisories',
        RiderNav.report => 'Saves offline first · GPS tagged',
        RiderNav.history => 'Completed deliveries · this month',
        RiderNav.queue => tracking.queued > 0
            ? '${tracking.queued} positions queued · sync when online'
            : 'Queued actions · sync when online',
      };

  /// Route id and destination come from the rider logistics service so the
  /// header matches the trip panel.
  String _tripSubtitle(RiderTrackingState tracking) {
    final rider = ref.watch(riderLogisticsProvider).rider;
    final trip = rider?.routeId == null ? 'No active trip' : 'Route ${rider!.routeId}';
    if (tracking.isSharing) return '$trip · sharing live location';
    return rider?.destination == null ? trip : '$trip · to ${rider!.destination}';
  }

  RiderTrackingController get _tracker => ref.read(riderTrackingProvider.notifier);

  String? get _activeShipmentId => ref.read(riderContextProvider).valueOrNull?.activeShipment?.id;

  Future<void> _startSharing({String? shipmentId}) =>
      _tracker.start(shipmentId: shipmentId ?? _activeShipmentId);

  /// What the officer-facing rules said, or a plain connectivity message.
  String _rpcMessage(Object e) => e is PostgrestException
      ? e.message
      : 'Could not reach the server. Check your connection and try again.';

  /// Runs one shipment action, refreshes the list either way (a failure usually
  /// means the shipment changed under us), and tells the rider what happened.
  Future<bool> _shipmentAction(Future<void> Function() run, {required String success}) async {
    try {
      await run();
      ref.invalidate(riderContextProvider);
      _notify(success);
      return true;
    } catch (e) {
      ref.invalidate(riderContextProvider);
      _notify(_rpcMessage(e));
      return false;
    }
  }

  Future<void> _respond(RiderShipment s, bool accept, String? reason) => _shipmentAction(
        () => ref.read(riderRepositoryProvider).respondToShipment(s.id, accept, reason: reason),
        success: accept
            ? '${s.shipmentNumber} accepted. Start the trip when you are ready.'
            : '${s.shipmentNumber} declined. Your dispatcher has been told.',
      );

  Future<void> _startTrip(RiderShipment s) async {
    final ok = await _shipmentAction(
      () => ref.read(riderRepositoryProvider).advanceShipment(s.id, 'in_transit'),
      success: 'Trip started for ${s.shipmentNumber}.',
    );
    if (!ok) return;
    ref.read(mockRepositoryProvider.notifier).setRiderTripStatus(RiderTripStatus.enRoute);
    await _startSharing(shipmentId: s.id);
    if (mounted) setState(() => _nav = RiderNav.trip);
  }

  Future<void> _arrive(RiderShipment s) async {
    final ok = await _shipmentAction(
      () => ref.read(riderRepositoryProvider).advanceShipment(s.id, 'arrived'),
      success: 'Arrival recorded for ${s.shipmentNumber}.',
    );
    if (!ok) return;
    ref.read(mockRepositoryProvider.notifier).setRiderTripStatus(RiderTripStatus.arrived);
    await _tracker.setPaused(true);
  }

  Future<void> _completeDelivery(RiderShipment s) async {
    final ok = await _shipmentAction(
      () => ref.read(riderRepositoryProvider).advanceShipment(s.id, 'completed'),
      success: '${s.shipmentNumber} delivered.',
    );
    if (ok && mounted) setState(() => _nav = RiderNav.dashboard);
  }

  Future<void> _signOut() async {
    final unsent = ref.read(mockRepositoryProvider).riderQueueCount +
        ref.read(riderTrackingProvider).queued;
    if (!await confirmSignOut(context, unsent)) return;
    // Never leave a foreground service running for a signed-out account.
    await _tracker.stop();
    widget.onSignOut();
  }

  /// Truthful confirmation for rider actions. Queued items live only on
  /// this device, so the copy must not claim anything was sent.
  void _notify(String message, {bool showQueue = false}) {
    if (!mounted) return;
    HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: showQueue
            ? SnackBarAction(
                label: 'View queue',
                onPressed: () => setState(() => _nav = RiderNav.queue),
              )
            : null,
      ));
  }

  Future<void> _checkIn() async {
    await _tracker.captureNow();
    // On failure the live-sharing card already shows the GPS error.
    if (ref.read(riderTrackingProvider).error == null) {
      _notify('Location captured');
    }
  }

  bool get _canPop =>
      !_drawerOpen && !_profileOpen && _nav == RiderNav.dashboard;

  void _handleBack() => setState(() {
        if (_profileOpen) {
          _profileOpen = false;
        } else if (_drawerOpen) {
          _drawerOpen = false;
        } else {
          _nav = RiderNav.dashboard;
        }
      });

  @override
  Widget build(BuildContext context) {
    final appState = ref.watch(mockRepositoryProvider);
    final tracking = ref.watch(riderTrackingProvider);
    final riderCtx = ref.watch(riderContextProvider).valueOrNull;
    ref.watch(riderShipmentSyncProvider);
    final online = ref.watch(isOnlineProvider).valueOrNull ?? true;
    final officer = ref.watch(currentProfileProvider)?.toOfficer() ?? riderOfficer;
    final offline = appState.isOffline || !online;

    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
      backgroundColor: AppColors.paper,
      // The map sheet owns the bottom of Offline Navigation.
      floatingActionButton: _nav == RiderNav.offlineNav ? null : const ChatButton(),
      body: Stack(
        children: [
          Column(
            children: [
              AppHeader(
                title: _title,
                subtitle: _subtitle(officer, riderCtx, tracking),
                roleInitials: 'RD',
                alertCount: const {'critical', 'high'}.contains(riderCtx?.tripShipment?.riskLevel) ? 1 : 0,
                onMenu: () => setState(() => _drawerOpen = true),
                onBell: () => setState(() => _nav = RiderNav.routeAlerts),
                onAvatar: () => setState(() => _profileOpen = true),
              ),
              OfflineBanner(isOffline: offline),
              Expanded(
                  child: screenFade(context, _nav,
                      _buildBody(appState, tracking, riderCtx, online))),
            ],
          ),
          if (_drawerOpen)
            Positioned.fill(
              child: RiderDrawer(
                current: _nav,
                officer: officer,
                queueCount: appState.riderQueueCount + tracking.queued,
                onNavigate: (nav) => setState(() => _nav = nav),
                onClose: () => setState(() => _drawerOpen = false),
                onSignOut: _signOut,
              ),
            ),
          if (_profileOpen)
            Positioned.fill(
              child: ProfileSheet(
                role: AppRole.rider,
                officer: officer,
                onClose: () => setState(() => _profileOpen = false),
                onSignOut: _signOut,
              ),
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildBody(
    MockAppState appState,
    RiderTrackingState tracking,
    riderCtx,
    bool online,
  ) {
    final repository = ref.read(mockRepositoryProvider.notifier);
    return RiderDashboard(
      section: _nav,
      appState: appState,
      tracking: tracking,
      riderContext: riderCtx,
      online: online,
      onNavigate: (nav) => setState(() => _nav = nav),
      onToggleOffline: repository.toggleOffline,
      onStartTrip: _startTrip,
      onPauseTrip: () {
        repository.setRiderTripStatus(RiderTripStatus.paused);
        _tracker.setPaused(true);
      },
      onResumeTrip: () {
        repository.setRiderTripStatus(RiderTripStatus.enRoute);
        if (tracking.isSharing) {
          _tracker.setPaused(false);
        } else {
          _startSharing();
        }
      },
      onRespond: _respond,
      onArrive: _arrive,
      onCompleteDelivery: _completeDelivery,
      onAddProof: () {
        repository.queueProof(ProofOfDelivery(
          id: 'POD-${DateTime.now().millisecondsSinceEpoch}',
          type: DeliveryProofType.photo,
          recipient: 'Dr. M. Khongwir',
          timestamp: DateTime.now(),
        ));
        repository.markRiderProofSubmitted();
        _notify('Delivery proof saved on this device. Not sent yet.',
            showQueue: true);
      },
      onReportIssue: () {
        repository.queueIssue(
          RiderIssueReport(
            id: 'ISS-${DateTime.now().millisecondsSinceEpoch}',
            type: VehicleIssueType.other,
            description: 'Road condition reported from active route',
            severity: Priority.medium,
            timestamp: DateTime.now(),
          ),
        );
        _notify('Issue saved on this device. Not sent yet.', showQueue: true);
      },
      onToggleSharing: () {
        if (tracking.isSharing) {
          _tracker.stop();
        } else {
          _startSharing();
        }
      },
      onCheckIn: _checkIn,
      onRefresh: () async {
        ref.invalidate(myRoutesMlRiskProvider);
        ref.invalidate(riderContextProvider);
        await ref.read(riderContextProvider.future);
      },
      onRetrySync: _tracker.retryNow,
      onDismissTrackingError: _tracker.clearError,
    );
  }
}
