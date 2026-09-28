import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/supabase/supabase_providers.dart';
import '../../../mock_data/models.dart';
import 'field_tasks_repository.dart';
import '../../../shared/widgets/widgets.dart';
import '../../../theme/colors.dart';
import '../../../theme/text_styles.dart';

class MyTasksScreen extends ConsumerStatefulWidget {
  final VoidCallback onBack;
  /// Next step offered when the list is empty.
  final VoidCallback? onReport;
  const MyTasksScreen({super.key, required this.onBack, this.onReport});

  @override
  ConsumerState<MyTasksScreen> createState() => _MyTasksScreenState();
}

class _MyTasksScreenState extends ConsumerState<MyTasksScreen> {
  List<FieldTask> _tasks = const [];
  TaskStatus? _filter; // null = all

  static const _tabs = [
    (null,              'All'),
    (TaskStatus.pending,    'Pending'),
    (TaskStatus.inProgress, 'In Progress'),
    (TaskStatus.awaitingVerification, 'Awaiting Verification'),
    (TaskStatus.completed,  'Completed'),
    (TaskStatus.overdue,    'Overdue'),
    (TaskStatus.rejected,   'Rejected'),
  ];

  List<FieldTask> get _filtered => _filter == null
      ? _tasks
      : _tasks.where((t) => t.status == _filter).toList();

  int _count(TaskStatus? s) =>
      s == null ? _tasks.length : _tasks.where((t) => t.status == s).length;

  Future<void> _run(String id, Future<void> Function(FieldTask) action, String done) async {
    final task = _tasks.where((t) => t.id == id).firstOrNull;
    if (task == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action(task);
      messenger.showSnackBar(SnackBar(content: Text(done)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Task not updated: $e')));
    }
  }

  void _accept(String id) =>
      _run(id, (t) => startTask(ref.read(supabaseClientProvider), t), 'Task started.');

  void _complete(String id) => _run(id, (t) => completeTask(ref.read(supabaseClientProvider), t),
      'Marked complete. Awaiting District Officer review.');

  @override
  Widget build(BuildContext context) {
    final live = ref.watch(myFieldTasksProvider);
    _tasks = live.valueOrNull ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Back + heading
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back_ios, size: 16),
                label: const Text('Home'),
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: AppColors.navy900,
                ),
              ),
              const SizedBox(height: 8),
              Semantics(
                header: true,
                child: Text('My Tasks', style: AppTextStyles.pageHeading),
              ),
              Text(live.hasError ? 'Could not load tasks: ${live.error}' : 'Assigned to you · live',
                  style: AppTextStyles.bodySmall),
            ],
          ),
        ),
        // Tab bar
        const SizedBox(height: 10),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: _tabs.map((tab) {
              final active = _filter == tab.$1;
              return Semantics(
                button: true,
                selected: active,
                label: '${tab.$2}, ${_count(tab.$1)}',
                excludeSemantics: true,
                onTap: () {
                  HapticFeedback.selectionClick();
                  setState(() => _filter = tab.$1);
                },
                child: InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    setState(() => _filter = tab.$1);
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 44),
                    child: Container(
                  margin: const EdgeInsets.only(right: 4),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: active
                            ? AppColors.navy900
                            : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        tab.$2,
                        style: AppTextStyles.tabLabel.copyWith(
                          color: active
                              ? AppColors.navy900
                              : AppColors.slate500,
                          fontWeight: active
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: active
                              ? AppColors.navy900
                              : AppColors.slate500
                                  .withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '${_count(tab.$1)}',
                          style: AppTextStyles.eyebrow.copyWith(
                            color: active
                                ? Colors.white
                                : AppColors.slate500,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        Divider(color: AppColors.hairline, height: 1),
        // Task list
        Expanded(
          child: _filtered.isEmpty
              ? SingleChildScrollView(
                  child: EmptyState(
                    icon: Icons.assignment_outlined,
                    title: 'No tasks in this category',
                    message: 'Seen something on the road? Report it.',
                    actionLabel: 'Report an incident',
                    onAction: widget.onReport,
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _filtered.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: 12),
                  itemBuilder: (_, i) => _TaskCard(
                    task: _filtered[i],
                    onAccept: _accept,
                    onComplete: _complete,
                  ),
                ),
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  final FieldTask task;
  final ValueChanged<String> onAccept;
  final ValueChanged<String> onComplete;

  const _TaskCard({
    required this.task,
    required this.onAccept,
    required this.onComplete,
  });

  ChipTone get _statusTone {
    switch (task.status) {
      case TaskStatus.pending:    return ChipTone.saffron;
      case TaskStatus.inProgress: return ChipTone.navy;
      case TaskStatus.awaitingVerification: return ChipTone.saffron;
      case TaskStatus.completed:  return ChipTone.clear;
      case TaskStatus.overdue:    return ChipTone.critical;
      case TaskStatus.rejected:   return ChipTone.critical;
    }
  }

  String get _statusLabel {
    switch (task.status) {
      case TaskStatus.pending:    return 'Pending';
      case TaskStatus.inProgress: return 'In Progress';
      case TaskStatus.awaitingVerification: return 'Awaiting Verification';
      case TaskStatus.completed:  return 'Completed';
      case TaskStatus.overdue:    return 'Overdue';
      case TaskStatus.rejected:   return 'Rejected';
    }
  }

  @override
  Widget build(BuildContext context) {
    return CardSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(task.id.substring(0, 8).toUpperCase(), style: AppTextStyles.caption),
              const SizedBox(width: 8),
              PriorityBadge(level: task.priority),
              const Spacer(),
              StatusChip(
                  tone: _statusTone, label: _statusLabel),
            ],
          ),
          const SizedBox(height: 8),
          Text(task.title,
              style: AppTextStyles.cardTitle.copyWith(
                  fontWeight: FontWeight.w600, fontSize: 16)),
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.location_on_outlined,
                  size: 14, color: AppColors.slate500),
              const SizedBox(width: 4),
              Expanded(
                  child: Text(task.location,
                      style: AppTextStyles.bodySmall)),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.access_time_outlined,
                  size: 13, color: AppColors.slate500),
              const SizedBox(width: 4),
              Text('Due ${task.dueTime}',
                  style: AppTextStyles.caption),
              const SizedBox(width: 12),
              Text('Created ${task.createdTime}',
                  style: AppTextStyles.caption),
            ],
          ),
          const SizedBox(height: 12),
          _ActionRow(
              task: task,
              onAccept: onAccept,
              onComplete: onComplete),
        ],
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  final FieldTask task;
  final ValueChanged<String> onAccept;
  final ValueChanged<String> onComplete;
  const _ActionRow(
      {required this.task,
      required this.onAccept,
      required this.onComplete});

  @override
  Widget build(BuildContext context) {
    switch (task.status) {
      case TaskStatus.pending:
        return OutlinedButton(
          onPressed: () => onAccept(task.id),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
            minimumSize: Size.zero,
            textStyle: AppTextStyles.buttonSmall,
          ),
          child: const Text('Start Task'),
        );
      case TaskStatus.inProgress:
        return ElevatedButton(
          onPressed: () => onComplete(task.id),
          style: ElevatedButton.styleFrom(
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
            minimumSize: Size.zero,
            textStyle: AppTextStyles.buttonSmall,
          ),
          child: const Text('Complete Task'),
        );
      case TaskStatus.awaitingVerification:
        return Text('Submitted for verification',
            style: AppTextStyles.captionSemibold.copyWith(
                color: AppColors.saffronDark));
      case TaskStatus.completed:
        return Row(
          children: [
            Icon(Icons.check_circle_outline,
                size: 14, color: AppColors.deepGreen700),
            const SizedBox(width: 4),
            Text('Verified',
                style: AppTextStyles.captionSemibold.copyWith(
                    color: AppColors.deepGreen700)),
          ],
        );
      case TaskStatus.overdue:
        return ElevatedButton(
          onPressed: () => onAccept(task.id),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.signalRed700,
            padding: const EdgeInsets.symmetric(
                horizontal: 16, vertical: 8),
            minimumSize: Size.zero,
            textStyle: AppTextStyles.buttonSmall,
          ),
          child: const Text('Start Task'),
        );
      case TaskStatus.rejected:
        return Text(
            'Rejected by District Officer${task.verificationNote == null ? '' : ': ${task.verificationNote}'}',
            style: AppTextStyles.captionSemibold.copyWith(color: AppColors.signalRed700));
    }
  }
}
