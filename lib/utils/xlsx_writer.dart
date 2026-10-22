import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// How a cell looks. Workbooks collect the distinct styles they use and write them once.
class XlsxStyle {
  const XlsxStyle({
    this.bold = false,
    this.italic = false,
    this.size = 11,
    this.color = 'FF1F2937',
    this.fill,
    this.align = 'left',
    this.vAlign = 'center',
    this.wrap = false,
    this.numFmt,
    this.border = true,
    this.borderColor = 'FFD1D5DB',
    this.topRule,
    this.bottomRule,
    this.indent = 0,
  });

  final bool bold;
  final bool italic;
  final double size;
  final String color; // ARGB
  final String? fill; // ARGB solid fill
  final String align; // left, center, right
  final String vAlign; // top, center, bottom
  final bool wrap;
  final String? numFmt; // Excel number format code, e.g. '#,##0'
  final bool border; // thin border on all sides
  final String borderColor;
  final String? topRule; // medium top border colour (totals, section rules)
  final String? bottomRule; // medium bottom border colour
  final int indent;

  XlsxStyle copyWith({
    bool? bold,
    bool? italic,
    double? size,
    String? color,
    String? fill,
    bool clearFill = false,
    String? align,
    String? vAlign,
    bool? wrap,
    String? numFmt,
    bool? border,
    String? topRule,
    String? bottomRule,
    int? indent,
  }) =>
      XlsxStyle(
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        size: size ?? this.size,
        color: color ?? this.color,
        fill: clearFill ? null : (fill ?? this.fill),
        align: align ?? this.align,
        vAlign: vAlign ?? this.vAlign,
        wrap: wrap ?? this.wrap,
        numFmt: numFmt ?? this.numFmt,
        border: border ?? this.border,
        borderColor: borderColor,
        topRule: topRule ?? this.topRule,
        bottomRule: bottomRule ?? this.bottomRule,
        indent: indent ?? this.indent,
      );

  String get _fontKey => '$bold|$italic|$size|$color';
  String get _fillKey => fill ?? '';
  String get _borderKey => '$border|$borderColor|$topRule|$bottomRule';
}

/// A formula cell, e.g. `XlsxFormula('SUM(B8:B12)')` (no leading '=').
class XlsxFormula {
  const XlsxFormula(this.expression);
  final String expression;
}

class XlsxCell {
  const XlsxCell(this.value, [this.style]);

  /// String, num, DateTime (written as a real Excel date; the DateTime's fields are used as the
  /// wall-clock time), [XlsxFormula] or null.
  final Object? value;
  final XlsxStyle? style;
}

class XlsxSheet {
  XlsxSheet(this.name, {this.tabColor});
  final String name;
  final String? tabColor;
  final Map<int, double> columnWidths = <int, double>{};
  final Map<int, double> rowHeights = <int, double>{}; // 0-based row -> points
  final List<List<XlsxCell?>> rows = <List<XlsxCell?>>[];
  final List<String> merges = <String>[];
  final Map<String, String> links = <String, String>{}; // cell ref -> internal location, e.g. "'Fleet'!A1"
  String? autoFilter; // e.g. 'A8:G40'
  int? freezeRows; // rows kept visible at the top
  bool showGridLines = true;
  bool landscape = false;

  /// 0-based index of the next row to be written.
  int get next => rows.length;

  /// 1-based Excel row number of the next row.
  int get nextRow => rows.length + 1;

  void width(int col, double w) => columnWidths[col] = w;

  void add(List<Object?> values, {XlsxStyle? style, double? height}) {
    if (height != null) rowHeights[rows.length] = height;
    rows.add(<XlsxCell?>[for (final Object? v in values) v is XlsxCell ? v : (v == null && style == null ? null : XlsxCell(v, style))]);
  }

  void blank([double? height]) {
    if (height != null) rowHeights[rows.length] = height;
    rows.add(const <XlsxCell?>[]);
  }

  /// Fills [cols] cells of the row with [style] (so a merged banner is coloured edge to edge).
  void band(Object? value, XlsxStyle style, int cols, {double? height}) {
    add(<Object?>[XlsxCell(value, style), for (int i = 1; i < cols; i++) XlsxCell(null, style)], height: height);
    merges.add('A${rows.length}:${XlsxWorkbook.colName(cols - 1)}${rows.length}');
  }
}

/// Writes a real Office Open XML workbook (.xlsx) without any plug-in, so it works the same on
/// the web and on Android and opens in Excel, Google Sheets and phone viewers without warnings.
/// Nothing is locked: users can sort, filter and edit, and totals written as formulas follow.
class XlsxWorkbook {
  XlsxWorkbook({this.title, this.author});
  final String? title;
  final String? author;
  final List<XlsxSheet> sheets = <XlsxSheet>[];

  XlsxSheet sheet(String name, {String? tabColor}) {
    final XlsxSheet s = XlsxSheet(safeName(name), tabColor: tabColor);
    sheets.add(s);
    return s;
  }

  static String safeName(String n) {
    final String s = n.replaceAll(RegExp(r'[\[\]\*\?/\\:]'), ' ').trim();
    return s.length > 31 ? s.substring(0, 31) : (s.isEmpty ? 'Sheet' : s);
  }

  static String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');

  static String colName(int index) {
    String s = '';
    int n = index + 1;
    while (n > 0) {
      final int m = (n - 1) % 26;
      s = String.fromCharCode(65 + m) + s;
      n = (n - 1) ~/ 26;
    }
    return s;
  }

  /// Excel serial date of the wall-clock fields of [d].
  static double serial(DateTime d) {
    final DateTime u = DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second);
    return u.millisecondsSinceEpoch / 86400000.0 + 25569.0;
  }

  // ---------------------------------------------------------------- styles
  static const XlsxStyle _default = XlsxStyle(border: false);
  final List<XlsxStyle> _xfs = <XlsxStyle>[_default];
  final Map<String, int> _xfIndex = <String, int>{};
  final List<String> _fonts = <String>[];
  final List<String> _fills = <String>[];
  final List<String> _borders = <String>[];
  final List<String> _numFmts = <String>[];

  int _xf(XlsxStyle? s) {
    if (s == null) return 0;
    final String k = '${s._fontKey}#${s._fillKey}#${s._borderKey}#${s.align}|${s.vAlign}|${s.wrap}|${s.numFmt}|${s.indent}';
    return _xfIndex.putIfAbsent(k, () {
      _xfs.add(s);
      return _xfs.length - 1;
    });
  }

  int _idx(List<String> list, String key) {
    final int i = list.indexOf(key);
    if (i >= 0) return i;
    list.add(key);
    return list.length - 1;
  }

  String _stylesXml() {
    _fonts.clear();
    _fills
      ..clear()
      ..addAll(<String>['', 'gray125']);
    _borders.clear();
    _numFmts.clear();
    final List<String> xfXml = <String>[];
    final List<XlsxStyle> fontStyles = <XlsxStyle>[];
    final List<XlsxStyle> borderStyles = <XlsxStyle>[];
    for (final XlsxStyle s in _xfs) {
      final int font = _idx(_fonts, s._fontKey);
      if (font == fontStyles.length) fontStyles.add(s);
      final int fill = s.fill == null ? 0 : _idx(_fills, s._fillKey);
      final int border = _idx(_borders, s._borderKey);
      if (border == borderStyles.length) borderStyles.add(s);
      final int numFmt = s.numFmt == null ? 0 : 164 + _idx(_numFmts, s.numFmt!);
      xfXml.add('<xf numFmtId="$numFmt" fontId="$font" fillId="$fill" borderId="$border" xfId="0"'
          '${numFmt > 0 ? ' applyNumberFormat="1"' : ''} applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">'
          '<alignment horizontal="${s.align}" vertical="${s.vAlign}"${s.wrap ? ' wrapText="1"' : ''}${s.indent > 0 ? ' indent="${s.indent}"' : ''}/></xf>');
    }
    final StringBuffer b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">');
    if (_numFmts.isNotEmpty) {
      b.write('<numFmts count="${_numFmts.length}">');
      for (int i = 0; i < _numFmts.length; i++) {
        b.write('<numFmt numFmtId="${164 + i}" formatCode="${esc(_numFmts[i])}"/>');
      }
      b.write('</numFmts>');
    }
    b.write('<fonts count="${fontStyles.length}">');
    for (final XlsxStyle s in fontStyles) {
      b.write('<font>${s.bold ? '<b/>' : ''}${s.italic ? '<i/>' : ''}<sz val="${s.size}"/><color rgb="${s.color}"/><name val="Calibri"/><family val="2"/></font>');
    }
    b.write('</fonts><fills count="${_fills.length}">');
    b.write('<fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill>');
    for (int i = 2; i < _fills.length; i++) {
      b.write('<fill><patternFill patternType="solid"><fgColor rgb="${_fills[i]}"/><bgColor indexed="64"/></patternFill></fill>');
    }
    b.write('</fills><borders count="${borderStyles.length}">');
    for (final XlsxStyle s in borderStyles) {
      String side(String tag, String? rule) {
        if (rule != null) return '<$tag style="medium"><color rgb="$rule"/></$tag>';
        if (s.border) return '<$tag style="thin"><color rgb="${s.borderColor}"/></$tag>';
        return '<$tag/>';
      }

      b.write('<border>${side('left', null)}${side('right', null)}${side('top', s.topRule)}${side('bottom', s.bottomRule)}<diagonal/></border>');
    }
    b.write('</borders>');
    b.write('<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>');
    b.write('<cellXfs count="${xfXml.length}">${xfXml.join()}</cellXfs>');
    b.write('<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>');
    b.write('</styleSheet>');
    return b.toString();
  }

  // ---------------------------------------------------------------- sheets
  String _sheetXml(XlsxSheet s) {
    final StringBuffer b = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">');
    b.write('<sheetPr>${s.tabColor == null ? '' : '<tabColor rgb="${s.tabColor}"/>'}<pageSetUpPr fitToPage="1"/></sheetPr>');
    b.write('<sheetViews><sheetView workbookViewId="0"${s.showGridLines ? '' : ' showGridLines="0"'}'
        '${identical(s, sheets.first) ? ' tabSelected="1"' : ''}>');
    if (s.freezeRows != null && s.freezeRows! > 0) {
      b.write('<pane ySplit="${s.freezeRows}" topLeftCell="A${s.freezeRows! + 1}" activePane="bottomLeft" state="frozen"/>'
          '<selection pane="bottomLeft" activeCell="A${s.freezeRows! + 1}" sqref="A${s.freezeRows! + 1}"/>');
    }
    b.write('</sheetView></sheetViews>');
    b.write('<sheetFormatPr defaultRowHeight="16"/>');
    if (s.columnWidths.isNotEmpty) {
      b.write('<cols>');
      final List<int> cols = s.columnWidths.keys.toList()..sort();
      for (final int c in cols) {
        b.write('<col min="${c + 1}" max="${c + 1}" width="${s.columnWidths[c]}" customWidth="1"/>');
      }
      b.write('</cols>');
    }
    b.write('<sheetData>');
    for (int r = 0; r < s.rows.length; r++) {
      final double? h = s.rowHeights[r];
      b.write('<row r="${r + 1}"${h == null ? '' : ' ht="$h" customHeight="1"'}>');
      final List<XlsxCell?> row = s.rows[r];
      for (int c = 0; c < row.length; c++) {
        final XlsxCell? cell = row[c];
        if (cell == null) continue;
        final String ref = '${colName(c)}${r + 1}';
        final int st = _xf(cell.style);
        final Object? v = cell.value;
        if (v == null || (v is String && v.isEmpty)) {
          if (st != 0) b.write('<c r="$ref" s="$st"/>');
        } else if (v is XlsxFormula) {
          b.write('<c r="$ref" s="$st"><f>${esc(v.expression)}</f></c>');
        } else if (v is DateTime) {
          b.write('<c r="$ref" s="$st"><v>${serial(v)}</v></c>');
        } else if (v is num && v.isFinite) {
          b.write('<c r="$ref" s="$st"><v>$v</v></c>');
        } else if (v is bool) {
          b.write('<c r="$ref" s="$st" t="b"><v>${v ? 1 : 0}</v></c>');
        } else {
          b.write('<c r="$ref" s="$st" t="inlineStr"><is><t xml:space="preserve">${esc(v.toString())}</t></is></c>');
        }
      }
      b.write('</row>');
    }
    b.write('</sheetData>');
    if (s.autoFilter != null) b.write('<autoFilter ref="${s.autoFilter}"/>');
    if (s.merges.isNotEmpty) {
      b.write('<mergeCells count="${s.merges.length}">');
      for (final String m in s.merges) {
        b.write('<mergeCell ref="$m"/>');
      }
      b.write('</mergeCells>');
    }
    if (s.links.isNotEmpty) {
      b.write('<hyperlinks>');
      s.links.forEach((String ref, String loc) => b.write('<hyperlink ref="$ref" location="${esc(loc)}" display="${esc(loc)}"/>'));
      b.write('</hyperlinks>');
    }
    b.write('<pageMargins left="0.4" right="0.4" top="0.5" bottom="0.5" header="0.3" footer="0.3"/>');
    b.write('<pageSetup paperSize="9" orientation="${s.landscape ? 'landscape' : 'portrait'}" fitToWidth="1" fitToHeight="0"/>');
    b.write('<headerFooter><oddFooter>&amp;L${esc(title ?? '')}&amp;RPage &amp;P of &amp;N</oddFooter></headerFooter>');
    b.write('</worksheet>');
    return b.toString();
  }

  Uint8List build() {
    if (sheets.isEmpty) sheet('Sheet1');
    final Archive a = Archive();
    void put(String name, String content) {
      final List<int> bytes = utf8.encode(content);
      a.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    // Sheet XML first: it registers the styles used.
    final List<String> sheetXml = <String>[for (final XlsxSheet s in sheets) _sheetXml(s)];

    final StringBuffer types = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
      ..write('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
      ..write('<Default Extension="xml" ContentType="application/xml"/>')
      ..write('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
      ..write('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')
      ..write('<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>');
    for (int i = 0; i < sheets.length; i++) {
      types.write('<Override PartName="/xl/worksheets/sheet${i + 1}.xml" '
          'ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>');
    }
    types.write('</Types>');
    put('[Content_Types].xml', types.toString());
    put('_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>');
    put('docProps/core.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${esc(title ?? '')}</dc:title><dc:creator>${esc(author ?? '')}</dc:creator>'
        '</cp:coreProperties>');

    final StringBuffer wb = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<bookViews><workbookView activeTab="0"/></bookViews><sheets>');
    final StringBuffer rels = StringBuffer()
      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');
    final StringBuffer defined = StringBuffer();
    for (int i = 0; i < sheets.length; i++) {
      final XlsxSheet s = sheets[i];
      wb.write('<sheet name="${esc(s.name)}" sheetId="${i + 1}" r:id="rId${i + 1}"/>');
      rels.write('<Relationship Id="rId${i + 1}" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
          'Target="worksheets/sheet${i + 1}.xml"/>');
      put('xl/worksheets/sheet${i + 1}.xml', sheetXml[i]);
      if (s.autoFilter != null) {
        final List<String> p = s.autoFilter!.split(':');
        String abs(String ref) => ref.replaceAllMapped(RegExp(r'([A-Z]+)(\d+)'), (Match m) => '\$${m[1]}\$${m[2]}');
        defined.write('<definedName name="_xlnm._FilterDatabase" localSheetId="$i" hidden="1">'
            '\'${esc(s.name)}\'!${abs(p[0])}:${abs(p[1])}</definedName>');
      }
    }
    wb.write('</sheets>');
    if (defined.isNotEmpty) wb.write('<definedNames>$defined</definedNames>');
    wb.write('<calcPr calcId="191029" fullCalcOnLoad="1"/></workbook>');
    rels.write('<Relationship Id="rId${sheets.length + 1}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>');
    rels.write('</Relationships>');
    put('xl/workbook.xml', wb.toString());
    put('xl/_rels/workbook.xml.rels', rels.toString());
    put('xl/styles.xml', _stylesXml());

    return Uint8List.fromList(ZipEncoder().encode(a));
  }
}
