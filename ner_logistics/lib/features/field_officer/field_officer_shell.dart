import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../alerts/alerts_repository.dart';
import '../chat/chat_sheet.dart';
import '../../core/network/connectivity_provider.dart';
import '../../mock_data/mock_officers.dart';
import '../auth/application/auth_controller.dart';
import '../../shared/motion.dart';
import '../../shared/widgets/app_header.dart';
import '../../shared/widgets/confirm_dialog.dart';
import '../../shared/widgets/offline_banner.dart';
import '../../features/profile/profile_sheet.dart';
import '../../mock_data/models.dart';
import '../../services/geo_providers.dart';
import '../../theme/colors.dart';
import 'field_drawer.dart';
import 'dashboard/field_dashboard.dart';
import 'trip/route_screen.dart';
import 'tasks/my_tasks_screen.dart';
import 'report/report_screen.dart';
import 'alerts/alerts_screen.dart';
import 'route_status/route_status_screen.dart';
import 'logistics/logistics_screen.dart';
import 'reports/reports_screen.dart';
import 'report/report_outbox.dart';

/// FieldOfficerShell — top-level widget for the Field Officer track.
/// Owns nav state, drawer, header, offline banner, and profile sheet.
/// All sub-screens are rendered as children — no Navigator push.
class FieldOfficerShell extends ConsumerStatefulWidget {
  final VoidCallback onSignOut;

  const FieldOfficerShell({super.key, required this.onSignOut});

  @override
  ConsumerState<FieldOfficerShell> createState() => _FieldOfficerShellState();
}

class _FieldOfficerShellState extends ConsumerState<FieldOfficerShell> {
  /// Signed-in officer from Supabase; a neutral placeholder until the profile loads.
  Officer get _officer => ref.watch(currentProfileProvider)?.toOfficer() ?? fieldOfficer;

  FieldNav _nav = FieldNav.dashboard;
  bool _drawerOpen = false;
  bool _profileOpen = false;
  int _alertsBadge = 0;
  /// Type chosen from a dashboard quick action; pre-fills the report wizard.
  IncidentType? _reportType;
  /// The report wizard holds input that hasn't been submitted.
  bool _reportDirty = false;

  // Trip state — lifted here so the header subtitle can reflect it
  TripPhase _tripPhase = TripPhase.active;
  bool _postReroute = false;
  bool _riskUpgraded = false;

  Future<void> _go(FieldNav dest) async {
    setState(() => _drawerOpen = false);
    if (_nav == FieldNav.report && dest != FieldNav.report && _reportDirty) {
      final discard = await confirmDestructive(
        context,
        title: 'Discard this report?',
        message: "The report hasn't been submitted. Your entries will be lost.",
        confirmLabel: 'Discard',
        cancelLabel: 'Keep Editing',
      );
      if (!discard || !mounted) return;
    }
    if (dest == _nav) return;
    setState(() {
      _reportDirty = false;
      _reportType = null;
      _nav = dest;
    });
  }

  Future<void> _signOut() async {
    final unsent = ref.read(myOutboxProvider).valueOrNull?.length ?? 0;
    if (await confirmSignOut(context, unsent)) widget.onSignOut();
  }

  /// Android Back / iOS back gesture: close the top overlay first, then
  /// return to the dashboard, and only then leave the app.
  bool get _canPop =>
      !_drawerOpen && !_profileOpen && _nav == FieldNav.dashboard;

  void _handleBack() {
    if (_profileOpen) {
      setState(() => _profileOpen = false);
    } else if (_drawerOpen) {
      setState(() => _drawerOpen = false);
    } else {
      _go(FieldNav.dashboard);
    }
  }

  void _triggerRisk() {
    // The risk interrupt belongs to an active trip; without one there is nothing to interrupt.
    if (ref.read(fieldTripScenarioProvider) == null) return;
    setState(() {
      _nav = FieldNav.trip;
      if (_tripPhase == TripPhase.active && !_postReroute) {
        _tripPhase = TripPhase.interrupt;
        _alertsBadge = 1;
      }
    });
  }

  void _setTripPhase(TripPhase phase) {
    setState(() {
      _tripPhase = phase;
      if (phase == TripPhase.interrupt && !_postReroute) {
        _alertsBadge = 1;
      }
    });
  }

  String get _headerTitle {
    switch (_nav) {
      case FieldNav.dashboard:  return 'Field Officer Dashboard';
      case FieldNav.trip:
        if (_tripPhase == TripPhase.rerouted || _postReroute) {
          return 'Active trip · rerouted';
        }
        return 'Active trip';
      case FieldNav.tasks:      return 'My Tasks';
      case FieldNav.report:     return 'Report Incident';
      case FieldNav.route:      return 'Route Status';
      case FieldNav.logistics:  return 'Logistics';
      case FieldNav.alerts:     return 'Alerts';
      case FieldNav.reports:    return 'My Reports';
    }
  }

  String get _headerSubtitle {
    switch (_nav) {
      case FieldNav.dashboard:
        return '${_officer.name} · ${_officer.region}';
      case FieldNav.trip:
        final trip = ref.watch(fieldTripScenarioProvider);
        if (trip == null) return 'No active trip';
        if (_tripPhase == TripPhase.interrupt ||
            _tripPhase == TripPhase.calculating) {
          return '${trip.id} · risk update received';
        }
        if (_tripPhase == TripPhase.rerouted || _postReroute) {
          return '${trip.id} · rerouted';
        }
        return '${trip.id} · to ${trip.destinationLabel}';
      case FieldNav.tasks:      return 'Assigned to you · ${_officer.region}';
      case FieldNav.report:     return 'Saved on this device · not sent yet';
      case FieldNav.route:      return 'Routes · ${_officer.region}';
      case FieldNav.logistics:  return 'Active shipments · ${_officer.region}';
      case FieldNav.alerts:     return 'Active today · ${_officer.region}';
      case FieldNav.reports:    return '${_officer.region} · all reports';
    }
  }

  @override
  Widget build(BuildContext context) {
    final offline = !(ref.watch(isOnlineProvider).valueOrNull ?? true);
    ref.watch(reportSyncProvider); // sends queued incident reports in the background
    ref.watch(myOutboxProvider); // kept live so the sign-out guard sees unsent reports
    return PopScope(
      canPop: _canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
      backgroundColor: AppColors.paper,
      floatingActionButton: const ChatButton(),
      body: Stack(
        children: [
          Column(
            children: [
              AppHeader(
                title: _headerTitle,
                subtitle: _headerSubtitle,
                roleInitials: 'FO',
                alertCount: _alertsBadge + ref.watch(activeAlertCountProvider),
                onMenu: () => setState(() => _drawerOpen = true),
                onBell: () => _go(FieldNav.alerts),
                onAvatar: () => setState(() => _profileOpen = true),
              ),
              OfflineBanner(isOffline: offline),
              Expanded(child: screenFade(context, _nav, _buildBody(offline))),
            ],
          ),

          // Drawer overlay
          if (_drawerOpen)
            Positioned.fill(
              child: FieldDrawer(
                current: _nav,
                officer: _officer,
                alertCount: _alertsBadge + ref.watch(activeAlertCountProvider),
                onNavigate: _go,
                onClose: () => setState(() => _drawerOpen = false),
                onSignOut: _signOut,
              ),
            ),

          // Profile sheet overlay
          if (_profileOpen)
            Positioned.fill(
              child: ProfileSheet(
                role: AppRole.field,
                officer: _officer,
                onClose: () => setState(() => _profileOpen = false),
                onSignOut: _signOut,
              ),
            ),
        ],
      ),
      ),
    );
  }

  Widget _buildBody(bool offline) {
    switch (_nav) {
      case FieldNav.dashboard:
        return FieldDashboard(
          officer: _officer,
          onStartTask: () => _go(FieldNav.trip),
          onOpenTasks: () => _go(FieldNav.tasks),
          onViewIncidents: () => _go(FieldNav.alerts),
          onReportType: (type) => setState(() {
            _reportType = type;
            _nav = FieldNav.report;
          }),
        );
      case FieldNav.trip:
        return RouteScreen(
          phase: _tripPhase,
          postReroute: _postReroute,
          riskUpgraded: _riskUpgraded,
          isOffline: offline,
          onPhaseChange: _setTripPhase,
          onRerouted: () => setState(() {
            _postReroute = true;
            _riskUpgraded = false;
            _tripPhase = TripPhase.active;
            _alertsBadge = 0;
          }),
          onNotNow: () => setState(() {
            _riskUpgraded = true;
            _tripPhase = TripPhase.active;
          }),
          onReport: () => _go(FieldNav.report),
        );
      case FieldNav.tasks:
        return MyTasksScreen(
          onBack: () => _go(FieldNav.dashboard),
          onReport: () => _go(FieldNav.report),
        );
      case FieldNav.report:
        return ReportScreen(
          key: ValueKey(_reportType),
          initialType: _reportType,
          onDirtyChanged: (dirty) => _reportDirty = dirty,
        );
      case FieldNav.route:
        return const RouteStatusScreen();
      case FieldNav.logistics:
        return const LogisticsScreen();
      case FieldNav.alerts:
        return AlertsScreen(
          onCriticalTap: _triggerRisk,
          onAlertsCleared: () => setState(() => _alertsBadge = 0),
        );
      case FieldNav.reports:
        return const ReportsScreen();
    }
  }
}
