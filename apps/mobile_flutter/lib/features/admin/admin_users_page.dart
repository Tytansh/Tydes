import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_models.dart';
import '../../core/network/surf_repository.dart';

final adminUsersProvider = FutureProvider.autoDispose<List<AdminUserAccount>>(
  (ref) => ref.watch(surfRepositoryProvider).fetchAdminUsers(),
);

final adminReportsProvider = FutureProvider.autoDispose<List<AdminReport>>(
  (ref) => ref.watch(surfRepositoryProvider).fetchAdminReports(),
);

class AdminUsersPage extends ConsumerStatefulWidget {
  const AdminUsersPage({super.key});

  @override
  ConsumerState<AdminUsersPage> createState() => _AdminUsersPageState();
}

class _AdminUsersPageState extends ConsumerState<AdminUsersPage> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final users = ref.watch(adminUsersProvider);
    final reports = ref.watch(adminReportsProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tydes admin'),
        actions: [
          IconButton(
            tooltip: 'Refresh accounts',
            onPressed: () {
              ref.invalidate(adminUsersProvider);
              ref.invalidate(adminReportsProvider);
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: users.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _AdminError(
          message: error.toString().replaceFirst('Bad state: ', ''),
          onRetry: () => ref.invalidate(adminUsersProvider),
        ),
        data: (accounts) {
          final query = _query.trim().toLowerCase();
          final filtered = accounts.where((account) {
            if (query.isEmpty) return true;
            return account.email.toLowerCase().contains(query) ||
                account.displayName.toLowerCase().contains(query) ||
                account.handle.toLowerCase().contains(query);
          }).toList();
          final verified = accounts.where((user) => user.emailVerified).length;
          final premium = accounts.where((user) => user.premium).length;
          return RefreshIndicator.adaptive(
            onRefresh: () async {
              await Future.wait([
                ref.refresh(adminUsersProvider.future),
                ref.refresh(adminReportsProvider.future),
              ]);
            },
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: [
                Text(
                  'User directory',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Private account overview. Passwords are never shown here.',
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Reports',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    reports.when(
                      data: (items) => Badge(
                        isLabelVisible: items.isNotEmpty,
                        label: Text('${items.length}'),
                        child: const Icon(Icons.flag_outlined),
                      ),
                      loading: () => const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      error: (_, _) => const Icon(Icons.error_outline),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text('Newest reports appear first.'),
                const SizedBox(height: 10),
                reports.when(
                  loading: () => const LinearProgressIndicator(),
                  error: (error, _) => Card(
                    child: ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: const Text('Could not load reports'),
                      subtitle: Text(
                        error.toString().replaceFirst('Bad state: ', ''),
                      ),
                      trailing: IconButton(
                        tooltip: 'Retry',
                        onPressed: () => ref.invalidate(adminReportsProvider),
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  ),
                  data: (items) => items.isEmpty
                      ? const Card(
                          child: ListTile(
                            leading: Icon(Icons.check_circle_outline),
                            title: Text('No reports yet'),
                          ),
                        )
                      : Column(
                          children: items
                              .map((report) => _ReportCard(report: report))
                              .toList(),
                        ),
                ),
                const SizedBox(height: 26),
                const SizedBox(height: 18),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _Metric(label: 'Accounts', value: accounts.length),
                    _Metric(label: 'Verified', value: verified),
                    _Metric(label: 'Premium', value: premium),
                  ],
                ),
                const SizedBox(height: 18),
                TextField(
                  onChanged: (value) => setState(() => _query = value),
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search email, name, or @handle',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '${filtered.length} ${filtered.length == 1 ? 'account' : 'accounts'}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                if (filtered.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(child: Text('No matching accounts.')),
                  )
                else
                  ...filtered.map((account) => _AccountCard(account: account)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({required this.report});

  final AdminReport report;

  @override
  Widget build(BuildContext context) {
    final created = report.createdAt?.toLocal();
    final dateLabel = created == null
        ? ''
        : '${created.year}-${created.month.toString().padLeft(2, '0')}-${created.day.toString().padLeft(2, '0')} '
              '${created.hour.toString().padLeft(2, '0')}:${created.minute.toString().padLeft(2, '0')}';
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        leading: const CircleAvatar(child: Icon(Icons.flag_outlined)),
        title: Text('${report.targetType} report'),
        subtitle: Text(
          '${report.reason.isEmpty ? 'No reason supplied' : report.reason}\n'
          'Target: ${report.targetId}\nReporter: ${report.reporterUserId}'
          '${dateLabel.isEmpty ? '' : '\n$dateLabel'}',
        ),
        isThreeLine: true,
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 118),
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    decoration: BoxDecoration(
      color: const Color(0xFFE4F7F5),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: Theme.of(context).textTheme.headlineSmall),
        Text(label),
      ],
    ),
  );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account});

  final AdminUserAccount account;

  @override
  Widget build(BuildContext context) {
    final title = account.displayName.trim().isEmpty
        ? account.email.split('@').first
        : account.displayName;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            CircleAvatar(
              child: Text(title.isEmpty ? '?' : title[0].toUpperCase()),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  Text(account.email),
                  if (account.handle.isNotEmpty) Text('@${account.handle}'),
                ],
              ),
            ),
            Wrap(
              spacing: 6,
              children: [
                if (account.emailVerified)
                  const Tooltip(
                    message: 'Email verified',
                    child: Icon(Icons.mark_email_read_outlined),
                  ),
                if (account.premium)
                  const Tooltip(
                    message: 'Premium',
                    child: Icon(Icons.verified, color: Color(0xFF009FA5)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AdminError extends StatelessWidget {
  const _AdminError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lock_outline, size: 44),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}
