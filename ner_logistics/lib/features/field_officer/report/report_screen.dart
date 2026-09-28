import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../../../core/offline/outbox_db.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../mock_data/models.dart';
import 'report_outbox.dart';
import '../../../shared/map/map_models.dart';
import '../../../shared/map/ner_geo.dart';
import '../../../shared/map/ner_map.dart';
import '../../../shared/widgets/widgets.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';

/// Road condition options — identical to the web form (ROAD_CONDITIONS in web data/demo.ts).
const roadConditions = {
  'Fully Blocked': 'fully_blocked',
  'Partially Accessible': 'partially_accessible',
  'Passable with caution': 'passable_with_caution',
};

/// ReportScreen — 6-step incident report wizard.
/// Steps: Type → Location → Evidence → Details → Review → Success
class ReportScreen extends ConsumerStatefulWidget {
  final IncidentType? initialType;
  /// Reports whether the wizard holds unsent input, so the shell can
  /// confirm before discarding it.
  final ValueChanged<bool>? onDirtyChanged;
  const ReportScreen({super.key, this.initialType, this.onDirtyChanged});

  @override
  ConsumerState<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends ConsumerState<ReportScreen> {
  late int _step; // 1–6
  IncidentType? _type;
  String _severity = 'moderate';
  String _description = '';
  final List<String> _photos = [];
  Position? _pos;
  String? _gpsError;
  bool _locating = false;
  String _locName = '';
  String _route = '';
  String _landmark = '';
  LatLng? _pin; // placed by long-press on the map; overrides GPS like the web map pick
  String? _roadCondition;
  String _vehicles = '';
  String _blockage = '';
  bool _submitting = false;
  bool _submitted = false;
  SyncStatus _sync = SyncStatus.pending;
  String _reportId = '';
  DateTime? _evidenceShownAt;
  bool _dirty = false;
  OutboxEntry? _pendingEntry; // this report while it waits in the outbox

  static const _stepLabels = [
    'Type', 'Location', 'Evidence', 'Details', 'Review', 'Submit'
  ];

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    _step = widget.initialType != null ? 2 : 1;
    _locate();
  }

  bool get _photoAdded => _photos.isNotEmpty;

  Future<void> _locate() async {
    setState(() {
      _locating = true;
      _gpsError = null;
    });
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw 'Location services are turned off.';
      }
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
        throw 'Location permission was denied.';
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 20));
      if (mounted) setState(() => _pos = p);
    } on TimeoutException {
      if (mounted) setState(() => _gpsError = 'No GPS fix yet. Move to open sky and retry.');
    } catch (e) {
      if (mounted) setState(() => _gpsError = e.toString());
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _pickPhotos(ImageSource source) async {
    // ~1600 px JPEG keeps each photo well under the storage limit on slow links.
    final picker = ImagePicker();
    try {
      final picked = source == ImageSource.camera
          ? [await picker.pickImage(source: source, maxWidth: 1600, imageQuality: 80)]
          : await picker.pickMultiImage(maxWidth: 1600, imageQuality: 80);
      final paths = picked.whereType<XFile>().map((f) => f.path);
      if (mounted) setState(() => _photos.addAll(paths.take(5 - _photos.length)));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not add photo: $e')));
      }
    }
  }

  void _next() => setState(() => _step = (_step + 1).clamp(1, 6));
  void _back() => setState(() => _step = (_step - 1).clamp(1, 6));

  Future<void> _submit() async {
    final uid = ref.read(supabaseClientProvider).auth.currentUser?.id;
    if (uid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Your session has ended. Sign in again to report.')));
      return;
    }
    setState(() => _submitting = true);
    try {
      final clientId = const Uuid().v4();
      // Copy photos out of the picker's temp dir so they survive until sync.
      final dir = Directory(
          '${(await getApplicationDocumentsDirectory()).path}/outbox/$clientId');
      await dir.create(recursive: true);
      final files = <String>[];
      for (var i = 0; i < _photos.length; i++) {
        final ext = _photos[i].contains('.') ? _photos[i].split('.').last : 'jpg';
        files.add((await File(_photos[i]).copy('${dir.path}/$i.$ext')).path);
      }
      await ref.read(outboxDbProvider).enqueue(
        kind: incidentReportKind,
        clientId: clientId,
        userId: uid,
        payload: {
          'incident_type': _dbType(_type),
          'severity': _severity == 'low' ? 'info' : _severity,
          'description': _description.trim().isEmpty ? null : _description.trim(),
          'location_text': _locName.trim().isEmpty ? null : _locName.trim(),
          'route_text': _route.trim().isEmpty ? null : _route.trim(),
          'lat': _pin?.latitude ?? _pos?.latitude,
          'lng': _pin?.longitude ?? _pos?.longitude,
          'landmark': _landmark.trim().isEmpty ? null : _landmark.trim(),
          'road_condition': roadConditions[_roadCondition],
          'vehicles_affected': int.tryParse(_vehicles.trim()),
          'estimated_blockage': _blockage.trim().isEmpty ? null : _blockage.trim(),
        },
        filePaths: files,
      );
      unawaited(ref.read(reportSyncProvider).flush(uid));
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitted = true;
        _sync = SyncStatus.pending;
        _reportId = clientId;
        _step = 6;
      });
      HapticFeedback.lightImpact();
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Report could not be saved: $e')));
    }
  }

  static String _dbType(IncidentType? t) => switch (t) {
        IncidentType.roadBlockage => 'road_blockage',
        IncidentType.flood => 'flood',
        IncidentType.landslide => 'landslide',
        IncidentType.accident => 'accident',
        IncidentType.infraDamage => 'infrastructure_damage',
        _ => 'other',
      };

  void _reset() => setState(() {
        _step = 1;
        _type = null;
        _severity = 'moderate';
        _description = '';
        _photos.clear();
        _locName = '';
        _route = '';
        _landmark = '';
        _pin = null;
        _roadCondition = null;
        _vehicles = '';
        _blockage = '';
        _reportId = '';
        _evidenceShownAt = null;
        _submitting = false;
        _submitted = false;
        _sync = SyncStatus.pending;
      });

  @override
  Widget build(BuildContext context) {
    ref.watch(reportSyncProvider); // keeps the background sender alive
    final queued = ref.watch(myOutboxProvider).valueOrNull;
    _pendingEntry =
        queued?.where((e) => e.clientId == _reportId).firstOrNull;
    ref.listen<AsyncValue<List<OutboxEntry>>>(myOutboxProvider, (_, next) {
      final list = next.valueOrNull;
      if (_submitted && list != null && !list.any((e) => e.clientId == _reportId)) {
        setState(() => _sync = SyncStatus.synced);
      }
    });
    final dirty = _step < 6 &&
        ((_type != null && _type != widget.initialType) ||
            _description.isNotEmpty ||
            _photoAdded);
    if (dirty != _dirty) {
      _dirty = dirty;
      WidgetsBinding.instance
          .addPostFrameCallback((_) {
        if (mounted) widget.onDirtyChanged?.call(dirty);
      });
    }
    return Column(
      children: [
        // Progress stepper (steps 1–5)
        if (_step < 6)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              children: [
                Row(
                  children: List.generate(_stepLabels.length, (i) {
                    final n = i + 1;
                    final done = n < _step;
                    final active = n == _step;
                    return Expanded(
                      child: Column(
                        children: [
                          Container(
                            constraints: const BoxConstraints(
                                minWidth: 24, minHeight: 24),
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: done
                                  ? AppColors.deepGreen700
                                  : active
                                      ? AppColors.navy900
                                      : AppColors.slate500
                                          .withOpacity(0.1),
                              shape: BoxShape.circle,
                            ),
                            child: done
                                ? const Icon(Icons.check,
                                    size: 12, color: Colors.white)
                                : Center(
                                    child: Text('$n',
                                        style: AppTextStyles.eyebrow
                                            .copyWith(
                                          color: active
                                              ? Colors.white
                                              : AppColors.slate500,
                                          fontSize: 11,
                                        )),
                                  ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _stepLabels[i],
                            style: AppTextStyles.eyebrow.copyWith(
                              color: active
                                  ? AppColors.navy900
                                  : done
                                      ? AppColors.deepGreen700
                                      : AppColors.slate500,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (_step - 1) / 5,
                    backgroundColor:
                        AppColors.slate500.withOpacity(0.1),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        AppColors.navy900),
                    minHeight: 4,
                  ),
                ),
              ],
            ),
          ),
        // Body
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: _buildStep(),
          ),
        ),
        // Back nav
        if (_step >= 2 && _step <= 5)
          Container(
            color: Colors.white,
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 12),
            child: TextButton.icon(
              onPressed: _back,
              icon: const Icon(Icons.arrow_back_ios, size: 14),
              label: Text('Back to ${_stepLabels[_step - 2]}'),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.navy900.withOpacity(0.7),
                padding: EdgeInsets.zero,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStep() {
    switch (_step) {
      case 1: return _Step1(selected: _type, onSelect: (t) {
        HapticFeedback.selectionClick();
        setState(() { _type = t; _next(); });
      });
      case 2: return _Step2(
        pos: _pos,
        error: _gpsError,
        locating: _locating,
        pin: _pin,
        locName: _locName,
        route: _route,
        landmark: _landmark,
        onRetry: _locate,
        onPin: (p) => setState(() => _pin = p),
        onLocName: (v) => setState(() => _locName = v),
        onRoute: (v) => setState(() => _route = v),
        onLandmark: (v) => setState(() => _landmark = v),
        onNext: _next,
      );
      case 3: return _Step3(
        photos: _photos,
        onAdd: _pickPhotos,
        onRemove: (p) => setState(() => _photos.remove(p)),
        onNext: _next,
        shownAt: _evidenceShownAt ??= DateTime.now(),
      );
      case 4: return _Step4(
        severity: _severity,
        description: _description,
        roadCondition: _roadCondition,
        vehicles: _vehicles,
        blockage: _blockage,
        onRoadCondition: (v) => setState(() => _roadCondition = v),
        onVehicles: (v) => setState(() => _vehicles = v),
        onBlockage: (v) => setState(() => _blockage = v),
        onSeverity: (s) {
          HapticFeedback.selectionClick();
          setState(() => _severity = s);
        },
        onDescription: (d) => setState(() => _description = d),
        onNext: _next,
      );
      case 5: return _Step5(
        type: _type,
        severity: _severity,
        description: _description,
        photoCount: _photos.length,
        location: [_locName.trim(), _route.trim()].where((v) => v.isNotEmpty).join(' · ').ifEmpty('—'),
        landmark: _landmark.trim().ifEmpty('—'),
        roadCondition: _roadCondition ?? 'Not assessed',
        vehicles: _vehicles.trim().ifEmpty('—'),
        blockage: _blockage.trim().ifEmpty('—'),
        gps: _pin != null
            ? '${_pin!.latitude.toStringAsFixed(5)}° N, ${_pin!.longitude.toStringAsFixed(5)}° E · placed on map'
            : _pos == null ? 'Not captured' : _fmtPos(_pos!),
        submitting: _submitting,
        onSubmit: _submit,
        onEdit: _back,
      );
      case 6: return _Step6(
        type: _type,
        reportId: _reportId,
        sync: _sync,
        lastError: _sync == SyncStatus.synced ? null : _pendingEntry?.lastError,
        onNewReport: _reset,
      );
      default: return const SizedBox.shrink();
    }
  }
}

// ── Step 1 — Type ─────────────────────────────────────────────────────────────

class _Step1 extends StatelessWidget {
  final IncidentType? selected;
  final ValueChanged<IncidentType> onSelect;
  const _Step1({required this.selected, required this.onSelect});

  static final _types = [
    (IncidentType.roadBlockage, AppColors.saffron600.withOpacity(0.5)),
    (IncidentType.flood,        AppColors.deepGreen700.withOpacity(0.4)),
    (IncidentType.landslide,    AppColors.signalRed700.withOpacity(0.4)),
    (IncidentType.accident,     AppColors.navy900.withOpacity(0.3)),
    (IncidentType.infraDamage,  AppColors.slate500.withOpacity(0.2)),
    (IncidentType.other,        AppColors.hairline),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
            header: true,
            child: Text('What happened?', style: AppTextStyles.sectionHeading)),
        const SizedBox(height: 4),
        Text('Select the incident type',
            style: AppTextStyles.bodySmall),
        const SizedBox(height: 16),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.3,
          children: _types.map((t) {
            final on = selected == t.$1;
            final shape = RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: on ? AppColors.navy900 : t.$2,
                width: on ? 2 : 1,
              ),
            );
            return Semantics(
              button: true,
              selected: on,
              label: '${t.$1.label} incident',
              onTap: () => onSelect(t.$1),
              excludeSemantics: true,
              child: Material(
                color: Colors.transparent,
                shape: shape,
                child: InkWell(
                  customBorder: shape,
                  onTap: () => onSelect(t.$1),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(t.$1.icon, size: 28, color: AppColors.navy900),
                      const SizedBox(height: 6),
                      Text(t.$1.label,
                          style: AppTextStyles.captionSemibold
                              .copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.navy900),
                          textAlign: TextAlign.center),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

String _fmtPos(Position p) =>
    '${p.latitude.toStringAsFixed(5)}° N, ${p.longitude.toStringAsFixed(5)}° E · ±${p.accuracy.round()} m';

// ── Step 2 — Location ─────────────────────────────────────────────────────────

class _Step2 extends StatelessWidget {
  final Position? pos;
  final LatLng? pin;
  final String? error;
  final bool locating;
  final String locName, route, landmark;
  final VoidCallback onRetry, onNext;
  final ValueChanged<LatLng> onPin;
  final ValueChanged<String> onLocName, onRoute, onLandmark;
  const _Step2({
    required this.pos,
    required this.pin,
    required this.error,
    required this.locating,
    required this.locName,
    required this.route,
    required this.landmark,
    required this.onRetry,
    required this.onPin,
    required this.onLocName,
    required this.onRoute,
    required this.onLandmark,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final ok = pos != null || pin != null;
    final color = ok ? AppColors.deepGreen700 : AppColors.saffron600;
    final point = pin ?? (pos == null ? null : LatLng(pos!.latitude, pos!.longitude));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
            header: true,
            child: Text('Location', style: AppTextStyles.sectionHeading)),
        Text('GPS from this device · add a place name', style: AppTextStyles.bodySmall),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: Row(
            children: [
              Icon(ok ? Icons.location_on_outlined : Icons.location_searching,
                  size: 18, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                        pin != null ? 'Pin placed on map' : ok ? 'GPS locked' : locating ? 'Getting GPS fix…' : 'No GPS fix',
                        style: AppTextStyles.captionSemibold
                            .copyWith(color: color, fontWeight: FontWeight.w700)),
                    Text(pin != null
                            ? '${pin!.latitude.toStringAsFixed(5)}° N, ${pin!.longitude.toStringAsFixed(5)}° E'
                            : pos != null ? _fmtPos(pos!) : (error ?? 'Waiting for location'),
                        style: AppTextStyles.caption),
                  ],
                ),
              ),
              if (!locating)
                TextButton(onPressed: onRetry, child: Text(ok ? 'Refresh' : 'Retry')),
            ],
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 200,
            child: NerMap(
              fitPoints: point == null ? const [NerGeo.regionSouthWest, NerGeo.regionNorthEast] : [point],
              fitKey: point,
              maxFitZoom: 14,
              incidents: [
                if (point != null)
                  MapIncident(id: 'pin', point: point, severity: Priority.high,
                      type: IncidentType.other, label: 'Incident location'),
              ],
              onLongPress: onPin,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text('Long-press the map to place or move the pin', style: AppTextStyles.caption),
        const SizedBox(height: 16),
        LabeledInput(
            label: 'Location name',
            initialValue: locName,
            placeholder: 'e.g. NH-6, Km 26 junction',
            onChanged: onLocName),
        LabeledInput(
            label: 'Route / road',
            initialValue: route,
            optional: true,
            placeholder: 'e.g. NH-6',
            onChanged: onRoute),
        LabeledInput(
            label: 'Nearby landmark',
            initialValue: landmark,
            optional: true,
            placeholder: 'e.g. Dhansiri River bridge, Km 34',
            onChanged: onLandmark),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: ok || locName.trim().isNotEmpty ? onNext : null,
            icon: const Icon(Icons.arrow_forward, size: 16),
            label: const Text('Continue to Evidence'),
          ),
        ),
        if (!ok && locName.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Needs a GPS fix, a map pin or a location name.', style: AppTextStyles.caption),
          ),
      ],
    );
  }
}

// ── Step 3 — Evidence ─────────────────────────────────────────────────────────

class _Step3 extends StatelessWidget {
  final List<String> photos;
  final ValueChanged<ImageSource> onAdd;
  final ValueChanged<String> onRemove;
  final VoidCallback onNext;
  final DateTime shownAt;
  const _Step3(
      {required this.photos,
      required this.onAdd,
      required this.onRemove,
      required this.onNext,
      required this.shownAt});

  @override
  Widget build(BuildContext context) {
    final full = photos.length >= 5;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
            header: true,
            child: Text('Evidence', style: AppTextStyles.sectionHeading)),
        Text('Up to 5 photos · sent when the device is online',
            style: AppTextStyles.bodySmall),
        const SizedBox(height: 16),
        if (photos.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in photos)
                Stack(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.file(File(p),
                          width: 96, height: 96, fit: BoxFit.cover,
                          semanticLabel: 'Evidence photo'),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      child: IconButton(
                        tooltip: 'Remove photo',
                        onPressed: () => onRemove(p),
                        icon: const Icon(Icons.cancel, color: Colors.white),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        const SizedBox(height: 12),
        ElevatedButton.icon(
          onPressed: full ? null : () => onAdd(ImageSource.camera),
          icon: const Icon(Icons.camera_alt_outlined, size: 18),
          label: const Text('Take photo'),
          style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: full ? null : () => onAdd(ImageSource.gallery),
          icon: const Icon(Icons.photo_library_outlined, size: 18),
          label: const Text('Upload from gallery'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 48)),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            children: [
              Icon(Icons.access_time_outlined, size: 15, color: AppColors.slate500),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Timestamp: ${TimeOfDay.fromDateTime(shownAt).format(context)} · Location from device',
                  style: AppTextStyles.caption,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: TextButton.icon(
            onPressed: onNext,
            icon: const Icon(Icons.arrow_forward, size: 16),
            label: Text(photos.isEmpty ? 'Continue without photos' : 'Continue to Details'),
          ),
        ),
      ],
    );
  }
}

// ── Step 4 — Details ──────────────────────────────────────────────────────────

class _Step4 extends StatelessWidget {
  final String severity;
  final String description;
  final String? roadCondition;
  final String vehicles, blockage;
  final ValueChanged<String?> onRoadCondition;
  final ValueChanged<String> onVehicles, onBlockage;
  final ValueChanged<String> onSeverity;
  final ValueChanged<String> onDescription;
  final VoidCallback onNext;

  const _Step4({
    required this.severity,
    required this.description,
    required this.roadCondition,
    required this.vehicles,
    required this.blockage,
    required this.onRoadCondition,
    required this.onVehicles,
    required this.onBlockage,
    required this.onSeverity,
    required this.onDescription,
    required this.onNext,
  });

  static const _severities = [
    ('low',      'Low'),
    ('moderate', 'Moderate'),
    ('high',     'High'),
    ('critical', 'Critical'),
  ];

  Color _sevColor(String s) {
    switch (s) {
      case 'low':      return AppColors.deepGreen700;
      case 'moderate': return AppColors.saffron600;
      case 'high':     return AppColors.saffron600;
      case 'critical': return AppColors.signalRed700;
      default:         return AppColors.navy900;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
            header: true,
            child: Text('Incident details', style: AppTextStyles.sectionHeading)),
        Text('Describe what you observed',
            style: AppTextStyles.bodySmall),
        const SizedBox(height: 16),
        FieldLabel('Severity'),
        const SizedBox(height: 8),
        Row(
          children: _severities.map((s) {
            final on = severity == s.$1;
            final c = _sevColor(s.$1);
            return Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Semantics(
                  button: true,
                  selected: on,
                  label: 'Severity ${s.$2}',
                  onTap: () => onSeverity(s.$1),
                  excludeSemantics: true,
                  child: Material(
                    color: Colors.transparent,
                    child: Ink(
                      decoration: BoxDecoration(
                        color: on ? c.withOpacity(0.1) : Colors.white,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: on ? c : AppColors.hairline,
                          width: on ? 2 : 1,
                        ),
                      ),
                      child: InkWell(
                        onTap: () => onSeverity(s.$1),
                        borderRadius: BorderRadius.circular(6),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 44),
                          child: Center(
                            child: Text(
                              s.$2,
                              style: AppTextStyles.eyebrow.copyWith(
                                color: on ? c : AppColors.slate500,
                                fontWeight: FontWeight.w700,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        FieldLabel('Description'),
        const SizedBox(height: 8),
        TextField(
          maxLines: 4,
          onChanged: onDescription,
          style: AppTextStyles.inputText,
          decoration: InputDecoration(
            hintText:
                'Describe what you see — road condition, extent of damage…',
            hintStyle: AppTextStyles.inputHint,
          ),
        ),
        const SizedBox(height: 16),
        LabeledSelect(
          label: 'Road condition',
          value: roadCondition,
          placeholder: 'Not assessed',
          options: roadConditions.keys.toList(),
          onChanged: onRoadCondition,
        ),
        Row(
          children: [
            Expanded(
              child: LabeledInput(
                label: 'Vehicles affected',
                initialValue: vehicles,
                optional: true,
                keyboardType: TextInputType.number,
                placeholder: 'Number of vehicles',
                onChanged: onVehicles,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: LabeledInput(
                label: 'Estimated blockage',
                initialValue: blockage,
                optional: true,
                placeholder: 'e.g. 4–6 hours',
                onChanged: onBlockage,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: onNext,
            icon: const Icon(Icons.arrow_forward, size: 16),
            label: const Text('Review report'),
          ),
        ),
      ],
    );
  }
}

// ── Step 5 — Review ───────────────────────────────────────────────────────────

class _Step5 extends StatelessWidget {
  final IncidentType? type;
  final String severity, description, location, gps, landmark, roadCondition, vehicles, blockage;
  final int photoCount;
  final bool submitting;
  final VoidCallback onSubmit, onEdit;

  const _Step5({
    required this.type,
    required this.severity,
    required this.description,
    required this.photoCount,
    required this.location,
    required this.gps,
    required this.landmark,
    required this.roadCondition,
    required this.vehicles,
    required this.blockage,
    required this.submitting,
    required this.onSubmit,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final rows = [
      ('Incident type',  type?.label ?? '—'),
      ('Severity',       severity[0].toUpperCase() + severity.substring(1)),
      ('Location',       location),
      ('Landmark',       landmark),
      ('GPS',            gps),
      ('Road condition', roadCondition),
      ('Vehicles',       vehicles),
      ('Est. blockage',  blockage),
      ('Photos',         photoCount == 0 ? 'No photo' : '$photoCount attached'),
      ('Description',    description.isEmpty ? 'No description' : description),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
            header: true,
            child: Text('Review & submit', style: AppTextStyles.sectionHeading)),
        Text('Confirm details before submitting',
            style: AppTextStyles.bodySmall),
        const SizedBox(height: 16),
        CardSurface(
          child: Column(
            children: rows.asMap().entries.map((e) {
              return Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  border: e.key < rows.length - 1
                      ? Border(
                          bottom:
                              BorderSide(color: AppColors.hairline))
                      : null,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(e.value.$1,
                          style: AppTextStyles.caption),
                    ),
                    Expanded(
                      child: Text(e.value.$2,
                          style: AppTextStyles.bodySmall.copyWith(
                              color: AppColors.navy900)),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.hairline),
          ),
          child: Row(
            children: [
              const Icon(Icons.cloud_queue, size: 16, color: AppColors.navy900),
              const SizedBox(width: 10),
              Expanded(
                child: Text('Saved on this device first, then sent automatically when online',
                    style: AppTextStyles.caption),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: ElevatedButton(
            onPressed: submitting ? null : onSubmit,
            child: submitting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                        color: Colors.white, strokeWidth: 2.5))
                : const Text('Submit report'),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: onEdit,
            child: const Text('Edit details'),
          ),
        ),
      ],
    );
  }
}

// ── Step 6 — Success ──────────────────────────────────────────────────────────

class _Step6 extends StatelessWidget {
  final IncidentType? type;
  final String reportId;
  final SyncStatus sync;
  final String? lastError;
  final VoidCallback onNewReport;
  const _Step6(
      {required this.type,
      required this.reportId,
      required this.sync,
      required this.lastError,
      required this.onNewReport});

  bool get sent => sync == SyncStatus.synced;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const SizedBox(height: 32),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            color: AppColors.deepGreen700.withOpacity(0.1),
            shape: BoxShape.circle,
            border: Border.all(
                color: AppColors.deepGreen700.withOpacity(0.4),
                width: 2),
          ),
          child: Icon(Icons.check,
              size: 28, color: AppColors.deepGreen700),
        ),
        const SizedBox(height: 16),
        Semantics(
            header: true,
            child: Text(sent ? 'Report sent' : 'Report saved', style: AppTextStyles.pageHeading)),
        const SizedBox(height: 4),
        Text(sent
            ? '${type?.label ?? 'Incident'} report sent to your district'
            : '${type?.label ?? 'Incident'} report queued on this device',
            style: AppTextStyles.bodySmall),
        const SizedBox(height: 24),
        CardSurface(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              _SuccessRow('Report ID', reportId.substring(0, 8).toUpperCase()),
              Divider(color: AppColors.hairline, height: 1),
              _SuccessRow('Delivery', sent
                  ? 'Received by the server.'
                  : lastError == null
                      ? 'Waiting for network. Sends automatically.'
                      : 'Retrying: $lastError'),
              Divider(color: AppColors.hairline, height: 1),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                        child: Text('Sync status',
                            style: AppTextStyles.caption)),
                    SyncChip(status: sync),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.saffronBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: AppColors.saffron600.withValues(alpha: 0.4)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline,
                  size: 15, color: AppColors.navy900),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sent
                      ? 'Officers of your district can now see this report. Track it under My Reports.'
                      : "Nobody has been notified yet. If it's urgent, call your district officer. Keep the app signed in until the report is sent.",
                  style: AppTextStyles.caption
                      .copyWith(color: AppColors.navy900),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: onNewReport,
            child: const Text('Report another incident'),
          ),
        ),
      ],
    );
  }
}

class _SuccessRow extends StatelessWidget {
  final String label, value;
  const _SuccessRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Text(label, style: AppTextStyles.caption)),
          const SizedBox(width: 12),
          Flexible(
            flex: 2,
            child: Text(value,
                textAlign: TextAlign.end,
                style: AppTextStyles.captionSemibold.copyWith(
                    color: AppColors.navy900,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}
