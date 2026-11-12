import 'package:flutter/material.dart';

/// Mount a tab on its first visit, then keep its scroll/form state intact.
/// Hidden tabs must not start requests or media work during initial rendering.
class RetainedTabStack extends StatefulWidget {
  const RetainedTabStack({
    super.key,
    required this.index,
    required this.children,
  });

  final int index;
  final List<Widget> children;

  @override
  State<RetainedTabStack> createState() => _RetainedTabStackState();
}

class _RetainedTabStackState extends State<RetainedTabStack> {
  final Set<int> _visited = {};

  @override
  void initState() {
    super.initState();
    _visited.add(widget.index);
  }

  @override
  void didUpdateWidget(covariant RetainedTabStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited.add(widget.index);
    _visited.removeWhere((index) => index >= widget.children.length);
  }

  @override
  Widget build(BuildContext context) => IndexedStack(
    index: widget.index,
    children: [
      for (var i = 0; i < widget.children.length; i++)
        TickerMode(
          enabled: i == widget.index,
          child: _visited.contains(i)
              ? widget.children[i]
              : const SizedBox.shrink(),
        ),
    ],
  );
}
