import 'package:flutter/material.dart';
import '../../mock_data/mock_repository.dart';
import '../../mock_data/models.dart';
import '../ml/presentation/ml_widgets.dart';
import '../../shared/widgets/widgets.dart';
import '../../theme/colors.dart';
import '../../theme/text_styles.dart';
import 'application/rider_tracking_controller.dart';
import 'domain/rider_context.dart';
import 'logistics/presentation/rider_logistics_panel.dart';
import 'offline_nav/presentation/offline_nav_page.dart';
import 'presentation/live_sharing_card.dart';
import 'rider_drawer.dart';
import 'rider_route_panel.dart';

class RiderDashboard extends StatelessWidget {
  final RiderNav section;
  final MockAppState appState;
  final ValueChanged<RiderNav> onNavigate;
  final VoidCallback onToggleOffline;
  final Future<void> Function(RiderShipment) onStartTrip;
  final VoidCallback onPauseTrip;
  final VoidCallback onResumeTrip;
  final Future<void> Function(RiderShipment, bool accept, String? reason) onRespond;
  final Future<void> Function(RiderShipment) onArrive;
  final Future<void> Function(RiderShipment) onCompleteDelivery;
  final VoidCallback onAddProof;
  final VoidCallback onReportIssue;

  // Live location sharing (Supabase-backed)
  final RiderTrackingState tracking;
  final RiderContext? riderContext;
  final bool online;
  final VoidCallback onToggleSharing;
  final VoidCallback onCheckIn;
  final Future<void> Function() onRefresh;
  final VoidCallback onRetrySync;
  final VoidCallback onDismissTrackingError;

  const RiderDashboard({
    super.key,
    required this.section,
    required this.appState,
    required this.onNavigate,
    required this.onToggleOffline,
    required this.onStartTrip,
    required this.onPauseTrip,
    required this.onResumeTrip,
    required this.onRespond,
    required this.onArrive,
    required this.onCompleteDelivery,
    required this.onAddProof,
    required this.onReportIssue,
    required this.tracking,
    required this.riderContext,
    required this.online,
    required this.onToggleSharing,
    required this.onCheckIn,
    required this.onRefresh,
    required this.onRetrySync,
    required this.onDismissTrackingError,
  });

  @override
  Widget build(BuildContext context) {
    switch (section) {
      case RiderNav.dashboard:
        return _DashboardHome(
          state: appState,
          onNavigate: onNavigate,
          onStartTrip: onStartTrip,
          onRespond: onRespond,
          onCompleteDelivery: onCompleteDelivery,
          onAddProof: onAddProof,
          onReportIssue: onReportIssue,
          onToggleOffline: onToggleOffline,
          tracking: tracking,
          riderContext: riderContext,
          online: online,
          onToggleSharing: onToggleSharing,
          onCheckIn: onCheckIn,
          onRefresh: onRefresh,
          onRetrySync: onRetrySync,
          onDismissTrackingError: onDismissTrackingError,
        );
      case RiderNav.deliveries:
        return _DeliveriesView(
            riderContext: riderContext, onRespond: onRespond, onNavigate: onNavigate);
      case RiderNav.trip:
        return _ActiveTripView(
          state: appState,
          riderContext: riderContext,
          tracking: tracking,
          onPause: onPauseTrip,
          onResume: onResumeTrip,
          onStart: onStartTrip,
          onArrive: onArrive,
          onComplete: onCompleteDelivery,
          onProof: onAddProof,
          onReport: onReportIssue,
        );
      case RiderNav.offlineNav:
        return OfflineNavPage(riderContext: riderContext);
      case RiderNav.routeAlerts:
        return _RouteAlertsView(state: appState, onNavigate: onNavigate);
      case RiderNav.report:
        return _ReportView(onSubmit: onReportIssue);
      case RiderNav.history:
        return _HistoryView(state: appState);
      case RiderNav.queue:
        return _QueueView(
          state: appState,
          tracking: tracking,
          online: online,
          onSync: onRetrySync,
        );
    }
  }
}

/// Greeting for the local hour, so it's never "Good morning" at night.
String _greeting(DateTime t) => t.hour < 12
    ? 'Good morning'
    : t.hour < 17
        ? 'Good afternoon'
        : 'Good evening';

class _DashboardHome extends StatelessWidget {
  final MockAppState state;
  final ValueChanged<RiderNav> onNavigate;
  final Future<void> Function(RiderShipment) onStartTrip;
  final Future<void> Function(RiderShipment, bool accept, String? reason) onRespond;
  final Future<void> Function(RiderShipment) onCompleteDelivery;
  final VoidCallback onAddProof;
  final VoidCallback onReportIssue;
  final VoidCallback onToggleOffline;
  final RiderTrackingState tracking;
  final RiderContext? riderContext;
  final bool online;
  final VoidCallback onToggleSharing;
  final VoidCallback onCheckIn;
  final Future<void> Function() onRefresh;
  final VoidCallback onRetrySync;
  final VoidCallback onDismissTrackingError;

  const _DashboardHome({
    required this.state,
    required this.onNavigate,
    required this.onStartTrip,
    required this.onRespond,
    required this.onCompleteDelivery,
    required this.onAddProof,
    required this.onReportIssue,
    required this.onToggleOffline,
    required this.tracking,
    required this.riderContext,
    required this.online,
    required this.onToggleSharing,
    required this.onCheckIn,
    required this.onRefresh,
    required this.onRetrySync,
    required this.onDismissTrackingError,
  });

  @override
  Widget build(BuildContext context) {
    final pending = riderContext?.pending ?? const <RiderShipment>[];
    final trip = riderContext?.tripShipment;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
                '${_greeting(DateTime.now())}, ${(riderContext?.fullName ?? 'Rider').split(' ').last}',
                style: AppTextStyles.pageHeading),
          ),
          const SizedBox(height: 4),
          Text(
              pending.isNotEmpty
                  ? 'You have ${pending.length} new assignment${pending.length == 1 ? '' : 's'} to answer.'
                  : trip == null
                      ? 'No delivery is assigned to you right now.'
                      : 'Your next action is ready below.',
              style: AppTextStyles.bodySmall),
          const SizedBox(height: 16),
          if (pending.isNotEmpty) ...[
            SectionTitle(title: 'New assignments'),
            for (final item in pending)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _PendingCard(shipment: item, onRespond: onRespond),
              ),
          ],
          SectionTitle(
            title: 'Active delivery',
            action: trip == null
                ? null
                : TextButton(
                    onPressed: () => onNavigate(RiderNav.trip),
                    child: const Text('Open trip')),
          ),
          if (trip == null)
            const CardSurface(
              child: EmptyState(
                icon: Icons.local_shipping_outlined,
                title: 'No active delivery',
                message: 'Deliveries assigned to you will appear here.',
              ),
            )
          else
            _TripSummaryCard(
              shipment: trip,
              onStartTrip: onStartTrip,
              onCompleteDelivery: onCompleteDelivery,
              onOpenTrip: () => onNavigate(RiderNav.trip),
            ),
          SectionTitle(
            title: 'Live location sharing',
            action: TextButton(
                onPressed: () => onNavigate(RiderNav.queue),
                child: const Text('Sync queue')),
          ),
          LiveSharingCard(
            tracking: tracking,
            riderContext: riderContext,
            online: online,
            onToggle: onToggleSharing,
            onCheckIn: onCheckIn,
            onRetry: onRetrySync,
            onDismissError: onDismissTrackingError,
          ),
          SectionTitle(title: 'Safety and route status'),
          RiderRouteStatusCard(onReview: () => onNavigate(RiderNav.trip)),
          SectionTitle(title: 'Road disruption risk · your routes'),
          const MlAssignedRoutesCard(),
          SectionTitle(title: 'Offline maps'),
          CardSurface(
            child: Material(
              type: MaterialType.transparency,
              child: ListTile(
              leading: const Icon(Icons.explore_outlined, color: AppColors.navy900),
              title: Text('Offline Navigation', style: AppTextStyles.bodySmallMedium),
              subtitle: Text('Turn-by-turn routes that work without signal',
                  style: AppTextStyles.caption),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onNavigate(RiderNav.offlineNav),
              ),
            ),
          ),
          SectionTitle(title: 'Quick actions'),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.7,
            children: [
              _ActionTile(icon: Icons.sos_outlined, label: 'SOS / emergency', tone: ChipTone.critical,
                  onTap: onReportIssue),
              _ActionTile(icon: Icons.report_problem_outlined, label: 'Report issue', tone: ChipTone.saffron,
                  onTap: onReportIssue),
              _ActionTile(icon: Icons.photo_camera_outlined, label: 'Add delivery proof', tone: ChipTone.navy,
                  onTap: onAddProof),
              _ActionTile(icon: Icons.location_on_outlined, label: 'Send check-in', tone: ChipTone.clear,
                  onTap: onCheckIn),
            ],
          ),
          SectionTitle(title: 'Offline and sync'),
          CardSurface(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon((state.isOffline || !online) ? Icons.wifi_off_outlined : Icons.wifi_outlined,
                    color: (state.isOffline || !online) ? AppColors.saffronDark : AppColors.deepGreen700),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    (state.isOffline || !online)
                        ? '${state.riderQueueCount + tracking.queued} actions saved on this device · not sent yet'
                        : tracking.queued > 0
                            ? 'Online · ${tracking.queued} position${tracking.queued == 1 ? '' : 's'} syncing'
                            // Proofs and issue reports have no upload yet.
                            : state.riderQueueCount > 0
                                ? 'Online · ${state.riderQueueCount} action${state.riderQueueCount == 1 ? '' : 's'} not sent yet'
                                : 'Online · everything synced',
                    style: AppTextStyles.bodySmallMedium,
                  ),
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

class _DeliveriesView extends StatelessWidget {
  final RiderContext? riderContext;
  final Future<void> Function(RiderShipment, bool accept, String? reason) onRespond;
  final ValueChanged<RiderNav> onNavigate;

  const _DeliveriesView({required this.riderContext, required this.onRespond, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    final shipments = riderContext?.shipments ?? const <RiderShipment>[];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Semantics(header: true, child: Text('Assigned deliveries', style: AppTextStyles.pageHeading)),
        const SizedBox(height: 4),
        Text('${shipments.length} shipment${shipments.length == 1 ? '' : 's'}', style: AppTextStyles.bodySmall),
        const SizedBox(height: 16),
        if (shipments.isEmpty)
          const EmptyState(
            icon: Icons.inventory_2_outlined,
            title: 'No assigned deliveries',
            message: 'New assignments from your district officer or the control room will appear here.',
          ),
        for (final item in shipments)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: item.isPending
                ? _PendingCard(shipment: item, onRespond: onRespond)
                : CardSurface(
                    padding: const EdgeInsets.all(14),
                    onTap: item.isInTransit || item.isArrived ? () => onNavigate(RiderNav.trip) : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(child: Text('${item.shipmentNumber} · ${item.cargoDescription ?? 'Shipment'}', style: AppTextStyles.cardTitle)),
                          RiskBadge(level: _riskOf(item.riskLevel), compact: true),
                        ]),
                        const SizedBox(height: 10),
                        _RoutePair(from: item.origin ?? '—', to: item.destination ?? '—'),
                        const SizedBox(height: 8),
                        Text(_shipmentMeta(item), style: AppTextStyles.caption),
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: StatusChip(
                              tone: item.isInTransit ? ChipTone.clear : ChipTone.navy,
                              label: item.statusLabel,
                              icon: Icons.info_outline),
                        ),
                      ],
                    ),
                  ),
          ),
      ],
    );
  }
}

class _ActiveTripView extends StatelessWidget {
  final MockAppState state;
  final RiderContext? riderContext;
  final RiderTrackingState tracking;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final Future<void> Function(RiderShipment) onStart;
  final Future<void> Function(RiderShipment) onArrive;
  final Future<void> Function(RiderShipment) onComplete;
  final VoidCallback onProof;
  final VoidCallback onReport;

  const _ActiveTripView({required this.state, required this.riderContext, required this.tracking,
      required this.onPause, required this.onResume, required this.onStart, required this.onArrive,
      required this.onComplete, required this.onProof, required this.onReport});

  @override
  Widget build(BuildContext context) {
    final item = riderContext?.tripShipment;
    if (item == null) {
      return const EmptyState(
        icon: Icons.alt_route_outlined,
        title: 'No active trip',
        message: 'Accept a delivery and start it to see its trip here.',
      );
    }
    final paused = tracking.status == TrackingStatus.paused;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        CardSurface(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(item.shipmentNumber, style: AppTextStyles.pageHeading)),
              RiskBadge(level: _riskOf(item.riskLevel)),
            ]),
            const SizedBox(height: 6),
            Text('${item.cargoDescription ?? 'Shipment'} · ${_shipmentMeta(item)}', style: AppTextStyles.bodySmall),
            const SizedBox(height: 12),
            _RoutePair(from: item.origin ?? '—', to: item.destination ?? '—'),
            const SizedBox(height: 14),
            RiderLogisticsPanel(isOffline: state.isOffline),
            const SizedBox(height: 16),
            Text('Road disruption risk ahead', style: AppTextStyles.bodySmallMedium),
            const SizedBox(height: 8),
            const MlTripAdvisory(),
            const SizedBox(height: 16),
            if (item.isAccepted)
              _AsyncButton(label: 'Start trip', icon: Icons.play_arrow_outlined, onPressed: () => onStart(item)),
            if (item.isInTransit) ...[
              if (tracking.isSharing)
                SizedBox(width: double.infinity, height: 46,
                    child: ElevatedButton.icon(
                      onPressed: paused ? onResume : onPause,
                      icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                      label: Text(paused ? 'Resume trip' : 'Pause trip'),
                    )),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: onReport, icon: const Icon(Icons.report_problem_outlined),
                  label: const Text('Report issue')),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: onProof, icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Add delivery proof')),
              const SizedBox(height: 8),
              _AsyncButton(label: 'Mark arrived', icon: Icons.flag_outlined, onPressed: () => onArrive(item)),
            ],
            if (item.isArrived) ...[
              Text('You have arrived. Complete the delivery once the goods are handed over.', style: AppTextStyles.bodySmall),
              const SizedBox(height: 8),
              OutlinedButton.icon(onPressed: onProof, icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Add delivery proof')),
              const SizedBox(height: 8),
              _AsyncButton(label: 'Complete delivery', icon: Icons.check_circle_outline, onPressed: () => onComplete(item)),
            ],
          ]),
        ),
      ],
    );
  }
}

class _RouteAlertsView extends StatelessWidget {
  final MockAppState state;
  final ValueChanged<RiderNav> onNavigate;
  const _RouteAlertsView({required this.state, required this.onNavigate});

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(16), children: [
      Semantics(header: true, child: Text('Route safety', style: AppTextStyles.pageHeading)),
      const SizedBox(height: 14),
      Text('Model risk on this trip', style: AppTextStyles.bodySmallMedium),
      const SizedBox(height: 8),
      const MlTripAdvisory(),
      const SizedBox(height: 18),
      Text('Mapped and reported hazards', style: AppTextStyles.bodySmallMedium),
      const SizedBox(height: 8),
      const RiderRouteHazards(),
      const SizedBox(height: 16),
      ElevatedButton.icon(onPressed: () => onNavigate(RiderNav.trip),
          icon: const Icon(Icons.navigation_outlined), label: const Text('Return to active trip')),
    ]);
  }
}

class _ReportView extends StatelessWidget {
  final VoidCallback onSubmit;
  const _ReportView({required this.onSubmit});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        Semantics(header: true, child: Text('Report an issue', style: AppTextStyles.pageHeading)),
        const SizedBox(height: 6),
        Text('Reports are saved locally first when connectivity is unavailable.', style: AppTextStyles.bodySmall),
        const SizedBox(height: 16),
        for (final row in const [
          ('Road or weather hazard', Icons.terrain_outlined),
          ('Vehicle breakdown or unsafe condition', Icons.car_repair_outlined),
          ('Delivery or recipient issue', Icons.inventory_2_outlined),
          ('Emergency assistance', Icons.sos_outlined),
        ])
          Padding(padding: const EdgeInsets.only(bottom: 10), child: CardSurface(
              padding: const EdgeInsets.all(14), onTap: onSubmit,
              child: Row(children: [Icon(row.$2, color: AppColors.navy900), const SizedBox(width: 12),
                  Expanded(child: Text(row.$1, style: AppTextStyles.bodySmallMedium)),
                  const Icon(Icons.chevron_right)]))),
      ]);
}

class _HistoryView extends StatelessWidget {
  final MockAppState state;
  const _HistoryView({required this.state});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        Semantics(header: true, child: Text('Delivery history', style: AppTextStyles.pageHeading)),
        const SizedBox(height: 14),
        if (state.riderAssignments.every((a) => a.status != RiderTripStatus.completed))
          const CardSurface(
            child: EmptyState(icon: Icons.history_outlined, title: 'No completed deliveries yet'),
          )
        else
          CardSurface(padding: const EdgeInsets.all(14), child: Row(children: [
            const Icon(Icons.check_circle_outline, color: AppColors.deepGreen700), const SizedBox(width: 12),
            Expanded(child: Text(
                '${state.riderAssignments.where((a) => a.status == RiderTripStatus.completed).length} deliveries completed',
                style: AppTextStyles.bodySmallMedium)),
          ])),
      ]);
}

class _QueueView extends StatelessWidget {
  final MockAppState state;
  final RiderTrackingState tracking;
  final bool online;
  final VoidCallback onSync;
  const _QueueView({required this.state, required this.tracking, required this.online, required this.onSync});
  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        Semantics(header: true, child: Text('Offline queue', style: AppTextStyles.pageHeading)),
        const SizedBox(height: 6),
        Text(
            '${state.riderQueueCount + tracking.queued} actions waiting to sync · '
            '${online ? 'online' : 'offline'}'
            '${tracking.lastSyncAt == null ? '' : ' · last position sync ${_hhmm(tracking.lastSyncAt!)}'}',
            style: AppTextStyles.bodySmall),
        const SizedBox(height: 14),
        for (final row in [
          ('Delivery proofs', state.queuedProofs.length, Icons.photo_camera_outlined),
          ('Issue reports', state.queuedIssues.length, Icons.report_problem_outlined),
          ('Location pings', tracking.queued, Icons.location_on_outlined),
        ])
          Padding(padding: const EdgeInsets.only(bottom: 10), child: CardSurface(padding: const EdgeInsets.all(14), child: Row(children: [
            Icon(row.$3, color: AppColors.navy900), const SizedBox(width: 12), Expanded(child: Text(row.$1)), Text('${row.$2}', style: AppTextStyles.cardTitle),
          ]))),
        ElevatedButton.icon(
            onPressed: tracking.uploading ? null : onSync,
            icon: const Icon(Icons.sync),
            label: Text(tracking.uploading ? 'Syncing…' : 'Retry sync')),
        if (tracking.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(tracking.error!, style: AppTextStyles.caption.copyWith(color: AppColors.saffronDark)),
          ),
      ]);

  static String _hhmm(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }
}

/// Database risk level -> the badge scale used across the rider app.
RiskLevel _riskOf(String? level) => switch (level) {
      'critical' || 'high' => RiskLevel.critical,
      'medium' => RiskLevel.caution,
      _ => RiskLevel.clear,
    };

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _when(DateTime? t) {
  if (t == null) return 'not set';
  final l = t.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}, ${l.day} ${_months[l.month - 1]}';
}

String _shipmentMeta(RiderShipment s) => [
      'ETA ${_when(s.estimatedArrival)}',
      if (s.routeNumber != null) s.routeNumber!,
      if (s.cargoWeightKg != null) '${s.cargoWeightKg!.toStringAsFixed(s.cargoWeightKg! % 1 == 0 ? 0 : 1)} kg',
    ].join(' · ');

/// Asks why the rider is declining; null when they back out. The reason goes to the officer.
Future<String?> _askDeclineReason(BuildContext context) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Decline this shipment?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('It goes back to your dispatcher to reassign. Tell them why.'),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Reason', border: OutlineInputBorder()),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Keep it')),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, v, __) => TextButton(
            onPressed: v.text.trim().isEmpty ? null : () => Navigator.pop(ctx, v.text.trim()),
            child: const Text('Decline'),
          ),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Button that shows a spinner and ignores taps while its async action runs.
class _AsyncButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final Future<void> Function() onPressed;
  const _AsyncButton({required this.label, required this.icon, required this.onPressed});

  @override
  State<_AsyncButton> createState() => _AsyncButtonState();
}

class _AsyncButtonState extends State<_AsyncButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    try {
      await widget.onPressed();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        height: 48,
        child: ElevatedButton.icon(
          onPressed: _busy ? null : _run,
          icon: _busy
              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(widget.icon),
          label: Text(widget.label),
        ),
      );
}

/// A new assignment: the rider accepts it or declines with a reason.
class _PendingCard extends StatefulWidget {
  final RiderShipment shipment;
  final Future<void> Function(RiderShipment, bool accept, String? reason) onRespond;
  const _PendingCard({required this.shipment, required this.onRespond});

  @override
  State<_PendingCard> createState() => _PendingCardState();
}

class _PendingCardState extends State<_PendingCard> {
  bool _busy = false;

  Future<void> _answer(bool accept) async {
    String? reason;
    if (!accept) {
      reason = await _askDeclineReason(context);
      if (reason == null) return;
    }
    setState(() => _busy = true);
    try {
      await widget.onRespond(widget.shipment, accept, reason);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.shipment;
    return CardSurface(
      padding: const EdgeInsets.all(14),
      borderColor: AppColors.saffron600.withOpacity(0.5),
      leftAccentColor: AppColors.saffron600,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('${s.shipmentNumber} · ${s.cargoDescription ?? 'Shipment'}', style: AppTextStyles.cardTitle)),
            RiskBadge(level: _riskOf(s.riskLevel), compact: true),
          ]),
          const SizedBox(height: 10),
          _RoutePair(from: s.origin ?? '—', to: s.destination ?? '—'),
          const SizedBox(height: 8),
          Text(_shipmentMeta(s), style: AppTextStyles.caption),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _answer(false), child: const Text('Decline'))),
            const SizedBox(width: 10),
            Expanded(child: ElevatedButton(onPressed: _busy ? null : () => _answer(true), child: Text(_busy ? 'Working…' : 'Accept'))),
          ]),
        ],
      ),
    );
  }
}

/// The shipment the rider is working on, with its one next action.
class _TripSummaryCard extends StatelessWidget {
  final RiderShipment shipment;
  final Future<void> Function(RiderShipment) onStartTrip;
  final Future<void> Function(RiderShipment) onCompleteDelivery;
  final VoidCallback onOpenTrip;
  const _TripSummaryCard({required this.shipment, required this.onStartTrip, required this.onCompleteDelivery, required this.onOpenTrip});

  @override
  Widget build(BuildContext context) {
    final s = shipment;
    final risk = _riskOf(s.riskLevel);
    return CardSurface(
      padding: const EdgeInsets.all(16),
      borderColor: risk == RiskLevel.critical ? AppColors.signalRed700.withOpacity(0.5) : AppColors.hairline,
      leftAccentColor: risk == RiskLevel.critical ? AppColors.signalRed700 : AppColors.saffron600,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(child: Text('${s.shipmentNumber} · ${s.cargoDescription ?? 'Shipment'}', style: AppTextStyles.cardTitle)),
            RiskBadge(level: risk),
          ]),
          const SizedBox(height: 12),
          _RoutePair(from: s.origin ?? '—', to: s.destination ?? '—'),
          const SizedBox(height: 12),
          Row(children: [
            _Metric(label: 'ETA', value: _when(s.estimatedArrival)),
            _Metric(label: 'Route', value: s.routeNumber ?? '—'),
            _Metric(label: 'Status', value: s.statusLabel),
          ]),
          const SizedBox(height: 14),
          if (s.isAccepted)
            _AsyncButton(label: 'Start trip', icon: Icons.play_arrow_outlined, onPressed: () => onStartTrip(s))
          else if (s.isArrived)
            _AsyncButton(label: 'Complete delivery', icon: Icons.check_circle_outline, onPressed: () => onCompleteDelivery(s))
          else
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: onOpenTrip,
                icon: const Icon(Icons.navigation_outlined),
                label: const Text('Continue trip'),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoutePair extends StatelessWidget {
  final String from;
  final String to;
  const _RoutePair({required this.from, required this.to});
  @override
  Widget build(BuildContext context) => Row(children: [
        Column(children: [const Icon(Icons.radio_button_checked, size: 14, color: AppColors.navy900), Container(width: 1, height: 20, color: AppColors.hairline), const Icon(Icons.location_on, size: 16, color: AppColors.signalRed700)]),
        const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(from, style: AppTextStyles.bodySmall), const SizedBox(height: 8), Text(to, style: AppTextStyles.bodySmallMedium)])),
      ]);
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;
  const _Metric({required this.label, required this.value});
  @override
  Widget build(BuildContext context) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: AppTextStyles.caption), const SizedBox(height: 3), Text(value, style: AppTextStyles.cardTitle, overflow: TextOverflow.ellipsis)]));
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final ChipTone tone;
  final VoidCallback onTap;
  const _ActionTile({required this.icon, required this.label, required this.tone, required this.onTap});
  @override
  Widget build(BuildContext context) => CardSurface(onTap: onTap, padding: const EdgeInsets.all(12), child: Row(children: [Icon(icon, color: _toneColor(tone), size: 21), const SizedBox(width: 8), Expanded(child: Text(label, style: AppTextStyles.captionSemibold))]));
}

Color _toneColor(ChipTone tone) => switch (tone) {
      ChipTone.critical => AppColors.signalRed700,
      ChipTone.saffron => AppColors.saffron600,
      ChipTone.clear => AppColors.deepGreen700,
      _ => AppColors.navy900,
    };
