import 'dart:math' as math;

import 'package:flutter/material.dart';

/// One column of an [AppDataTable].
class AppTableColumn<T> {
  const AppTableColumn({required this.label, required this.cell, this.flex = 1, this.sortKey, this.numeric = false});

  final String label;
  final Widget Function(T row, int index) cell;

  /// Share of the table width (like Expanded.flex).
  final int flex;

  /// Value the column sorts by; null = not sortable.
  final Comparable<Object?>? Function(T row)? sortKey;
  final bool numeric;
}

/// The app's table for long lists (users, complaints): sortable headers, hover, row tap and
/// pages of [pageSize] rows. Narrow screens scroll the table sideways instead of squeezing it.
class AppDataTable<T> extends StatefulWidget {
  const AppDataTable({
    super.key,
    required this.rows,
    required this.columns,
    this.onRowTap,
    this.pageSize = 12,
    this.minWidth = 820,
    this.rowHeight = 64,
    this.highlight,
    this.showPager = true,
  });

  /// False when the caller pages on the server and shows its own pager.
  final bool showPager;

  final List<T> rows;
  final List<AppTableColumn<T>> columns;
  final void Function(T row)? onRowTap;
  final int pageSize;
  final double minWidth;
  final double rowHeight;

  /// Optional left stripe colour per row (e.g. pending, archived).
  final Color? Function(T row)? highlight;

  @override
  State<AppDataTable<T>> createState() => _AppDataTableState<T>();
}

class _AppDataTableState<T> extends State<AppDataTable<T>> {
  static const Color _teal = Color(0xFF00796B);
  static const Color _ink = Color(0xFF1F2A27);
  static const Color _line = Color(0xFFE8EEEC);

  int? _sortColumn;
  bool _ascending = true;
  int _page = 0;
  int? _hover;

  @override
  void didUpdateWidget(covariant AppDataTable<T> old) {
    super.didUpdateWidget(old);
    if (old.rows.length != widget.rows.length) _page = 0;
  }

  List<T> get _sorted {
    final int? c = _sortColumn;
    final Comparable<Object?>? Function(T)? key = c == null ? null : widget.columns[c].sortKey;
    if (key == null) return widget.rows;
    final List<T> list = List<T>.of(widget.rows);
    list.sort((T a, T b) {
      final Comparable<Object?>? x = key(a), y = key(b);
      final int r = x == null ? (y == null ? 0 : 1) : (y == null ? -1 : x.compareTo(y));
      return _ascending ? r : -r;
    });
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final List<T> sorted = _sorted;
    final int pageSize = widget.showPager ? widget.pageSize : math.max(1, sorted.length);
    final int pages = math.max(1, (sorted.length / pageSize).ceil());
    final int page = _page.clamp(0, pages - 1);
    final int from = page * pageSize;
    final int to = math.min(sorted.length, from + pageSize);
    final List<T> visible = sorted.sublist(from, to);

    Widget header() => Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: const BoxDecoration(
            color: Color(0xFFF4F7F6),
            border: Border(bottom: BorderSide(color: _line)),
          ),
          child: Row(children: <Widget>[
            for (int i = 0; i < widget.columns.length; i++)
              Expanded(
                flex: widget.columns[i].flex,
                child: InkWell(
                  onTap: widget.columns[i].sortKey == null
                      ? null
                      : () => setState(() {
                            if (_sortColumn == i) {
                              _ascending = !_ascending;
                            } else {
                              _sortColumn = i;
                              _ascending = true;
                            }
                          }),
                  child: Row(
                    mainAxisAlignment: widget.columns[i].numeric ? MainAxisAlignment.end : MainAxisAlignment.start,
                    children: <Widget>[
                      Flexible(
                        child: Text(widget.columns[i].label.toUpperCase(),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                                color: _sortColumn == i ? _teal : const Color(0xFF6B7A75))),
                      ),
                      if (widget.columns[i].sortKey != null)
                        Icon(
                          _sortColumn == i ? (_ascending ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded) : Icons.unfold_more_rounded,
                          size: 14,
                          color: _sortColumn == i ? _teal : const Color(0xFFB0BCB8),
                        ),
                    ],
                  ),
                ),
              ),
          ]),
        );

    Widget row(T r, int index) {
      final bool hover = _hover == index;
      final Color? stripe = widget.highlight?.call(r);
      return MouseRegion(
        onEnter: (_) => setState(() => _hover = index),
        onExit: (_) => setState(() => _hover = null),
        child: Material(
          color: hover ? const Color(0xFFF2F8F6) : Colors.white,
          child: InkWell(
            onTap: widget.onRowTap == null ? null : () => widget.onRowTap!(r),
            child: Container(
              height: widget.rowHeight,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: const BorderSide(color: _line),
                  left: BorderSide(color: stripe ?? Colors.transparent, width: 3),
                ),
              ),
              child: Row(children: <Widget>[
                for (final AppTableColumn<T> c in widget.columns)
                  Expanded(
                    flex: c.flex,
                    child: Align(
                      alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft,
                      child: Padding(padding: const EdgeInsets.only(right: 10), child: c.cell(r, from + index)),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      );
    }

    Widget pager() => Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
          child: Row(children: <Widget>[
            Text(sorted.isEmpty ? 'No rows' : 'Showing ${from + 1}–$to of ${sorted.length}',
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Color(0xFF6B7A75))),
            const Spacer(),
            IconButton(
              tooltip: 'Previous page',
              onPressed: page > 0 ? () => setState(() => _page = page - 1) : null,
              icon: const Icon(Icons.chevron_left_rounded),
              color: _teal,
            ),
            Text('${page + 1} / $pages', style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w800, color: _ink)),
            IconButton(
              tooltip: 'Next page',
              onPressed: page < pages - 1 ? () => setState(() => _page = page + 1) : null,
              icon: const Icon(Icons.chevron_right_rounded),
              color: _teal,
            ),
          ]),
        );

    return LayoutBuilder(builder: (BuildContext context, BoxConstraints c) {
      final double width = math.max(c.maxWidth, widget.minWidth);
      final Widget table = SizedBox(
        width: width,
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          header(),
          for (int i = 0; i < visible.length; i++) row(visible[i], i),
        ]),
      );
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: _line),
          boxShadow: const <BoxShadow>[BoxShadow(color: Color(0x0F000000), blurRadius: 16, offset: Offset(0, 4))],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          width > c.maxWidth ? SingleChildScrollView(scrollDirection: Axis.horizontal, child: table) : table,
          if (widget.showPager) pager(),
        ]),
      );
    });
  }
}

/// Small coloured status pill used in tables.
class TablePill extends StatelessWidget {
  const TablePill(this.text, this.color, {super.key});
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
        child: Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Color.lerp(color, Colors.black, 0.25))),
      );
}
