import 'package:flutter/material.dart';
import '../utils/app_theme.dart';
import '../utils/app_localizations.dart';

class TermsAcceptanceDialog extends StatefulWidget {
  final Future<bool> Function() onAcceptAndSubmit;

  const TermsAcceptanceDialog({
    super.key,
    required this.onAcceptAndSubmit,
  });

  static Future<bool?> show(
    BuildContext context, {
    required Future<bool> Function() onAcceptAndSubmit,
  }) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isWide = screenWidth >= 600;

    if (isWide) {
      return showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 640,
              maxHeight: 720,
            ),
            child: TermsAcceptanceDialog(onAcceptAndSubmit: onAcceptAndSubmit),
          ),
        ),
      );
    } else {
      return showGeneralDialog<bool>(
        context: context,
        barrierDismissible: false,
        pageBuilder: (context, anim1, anim2) => Scaffold(
          body: SafeArea(
            child: TermsAcceptanceDialog(onAcceptAndSubmit: onAcceptAndSubmit),
          ),
        ),
      );
    }
  }

  @override
  State<TermsAcceptanceDialog> createState() => _TermsAcceptanceDialogState();
}

class _TermsAcceptanceDialogState extends State<TermsAcceptanceDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _isLoading = true;
  bool _hasError = false;
  bool _agreed = false;
  bool _isSubmitting = false;

  // The agreement can only be ticked after BOTH documents were scrolled to their end.
  final ScrollController _termsScroll = ScrollController();
  final ScrollController _privacyScroll = ScrollController();
  bool _readTerms = false;
  bool _readPrivacy = false;
  bool get _canAgree => _readTerms && _readPrivacy && !_isLoading && !_hasError && !_isSubmitting;

  void _checkRead() {
    bool atEnd(ScrollController c) => c.hasClients && c.position.extentAfter <= 24;
    final bool t = _readTerms || atEnd(_termsScroll);
    final bool pv = _readPrivacy || atEnd(_privacyScroll);
    if (t != _readTerms || pv != _readPrivacy) {
      setState(() {
        _readTerms = t;
        _readPrivacy = pv;
      });
    }
  }

  /// Opens the document still to be read (the checkbox explains why it is not available yet).
  void _showUnread() {
    if (!_readTerms) {
      _tabController.animateTo(0);
    } else if (!_readPrivacy) {
      _tabController.animateTo(1);
    }
  }

  String _termsContent = '';
  String _privacyContent = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _termsScroll.addListener(_checkRead);
    _privacyScroll.addListener(_checkRead);
    // A short document that fits without scrolling counts as read once it is shown.
    _tabController.addListener(() => WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _checkRead(); }));
    _loadDocumentContents();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _termsScroll.dispose();
    _privacyScroll.dispose();
    super.dispose();
  }

  Future<void> _loadDocumentContents() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      await Future.delayed(const Duration(milliseconds: 300));
      final terms = AppLocalizations.getTerms();
      final privacy = AppLocalizations.getPrivacy();

      if (terms.isEmpty || privacy.isEmpty) {
        throw Exception("Unable to load legal agreement documents.");
      }

      if (mounted) {
        setState(() {
          _termsContent = terms;
          _privacyContent = privacy;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    }
  }

  Future<void> _handleSubmit() async {
    if (!_agreed || _isLoading || _hasError || _isSubmitting) return;

    setState(() => _isSubmitting = true);

    try {
      final success = await widget.onAcceptAndSubmit();
      if (mounted) {
        if (success) {
          Navigator.pop(context, true);
        } else {
          setState(() => _isSubmitting = false);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final double screenWidth = MediaQuery.of(context).size.width;
    final bool isWide = screenWidth >= 600;

    return PopScope(
      canPop: !_isSubmitting,
      onPopInvokedWithResult: (didPop, result) {
        // Prevent back pop while submitting
      },
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: isWide ? BorderRadius.circular(24) : BorderRadius.zero,
          boxShadow: isWide
              ? [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.15),
                    blurRadius: 30,
                    offset: const Offset(0, 10),
                  )
                ]
              : null,
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE))),
              ),
              child: Row(
                children: [
                  const Icon(Icons.gavel_rounded, color: AppColors.tealText, size: 26),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      "Terms & Privacy Acceptance",
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w900,
                        color: AppColors.tealText,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _isSubmitting ? null : () => Navigator.pop(context, false),
                    icon: const Icon(Icons.close_rounded, color: Colors.grey),
                    tooltip: "Cancel",
                  ),
                ],
              ),
            ),

            // Tab Bar
            TabBar(
              controller: _tabController,
              labelColor: AppColors.tealText,
              unselectedLabelColor: Colors.grey.shade600,
              indicatorColor: AppColors.tealText,
              indicatorWeight: 3,
              labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              tabs: [
                _docTab("Terms & Conditions", _readTerms),
                _docTab("Privacy Policy", _readPrivacy),
              ],
            ),

            // Document Content
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(color: AppColors.tealText, strokeWidth: 3),
                          SizedBox(height: 16),
                          Text(
                            "Loading agreement documents...",
                            style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    )
                  : _hasError
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24.0),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.error_outline_rounded, color: Colors.red, size: 48),
                                const SizedBox(height: 12),
                                const Text(
                                  "Failed to load agreement content.",
                                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 16),
                                ElevatedButton.icon(
                                  onPressed: _loadDocumentContents,
                                  icon: const Icon(Icons.refresh_rounded),
                                  label: const Text("Retry Loading"),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: AppColors.tealText,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        )
                      : TabBarView(
                          controller: _tabController,
                          children: [
                            _buildDocumentScrollArea(_termsContent, _termsScroll),
                            _buildDocumentScrollArea(_privacyContent, _privacyScroll),
                          ],
                        ),
            ),

            // Bottom Controls Area
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Color(0xFFFAFAFA),
                border: Border(top: BorderSide(color: Color(0xFFEEEEEE))),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Explicit Checkbox
                  if (!_isLoading && !_hasError && !(_readTerms && _readPrivacy))
                    Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.tealText.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(children: [
                        Icon(Icons.swipe_up_rounded, size: 18, color: AppColors.tealText),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            "Scroll to the end of both documents to continue.",
                            style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Colors.grey.shade800),
                          ),
                        ),
                        _readChip("Terms", _readTerms),
                        const SizedBox(width: 6),
                        _readChip("Privacy", _readPrivacy),
                      ]),
                    ),
                  InkWell(
                    onTap: (_isLoading || _hasError || _isSubmitting)
                        ? null
                        : (_canAgree ? () => setState(() => _agreed = !_agreed) : _showUnread),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            height: 24,
                            width: 24,
                            child: Checkbox(
                              value: _agreed,
                              onChanged: _canAgree ? (v) => setState(() => _agreed = v ?? false) : null,
                              activeColor: AppColors.tealText,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Text(
                              "I have read and agree to the Terms & Conditions and acknowledge the Privacy Policy.",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF2C3E50),
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Action Buttons
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _isSubmitting ? null : () => Navigator.pop(context, false),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            side: const BorderSide(color: Colors.grey),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: const Text(
                            "Cancel",
                            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 15),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: (_agreed && _canAgree)
                              ? _handleSubmit
                              : null,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.tealText,
                            disabledBackgroundColor: AppColors.tealText.withOpacity(0.4),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            elevation: 0,
                          ),
                          child: _isSubmitting
                              ? const SizedBox(
                                  height: 20,
                                  width: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : const Text(
                                  "Accept & Submit",
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 15,
                                  ),
                                ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _docTab(String text, bool read) => Tab(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
          if (read) ...[
            const SizedBox(width: 6),
            Icon(Icons.check_circle_rounded, size: 16, color: AppColors.tealText),
          ],
        ]),
      );

  Widget _readChip(String text, bool read) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: read ? AppColors.tealText : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: read ? AppColors.tealText : Colors.grey.shade300),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(read ? Icons.check_rounded : Icons.more_horiz_rounded, size: 12, color: read ? Colors.white : Colors.grey.shade500),
          const SizedBox(width: 3),
          Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: read ? Colors.white : Colors.grey.shade600)),
        ]),
      );

  Widget _buildDocumentScrollArea(String textContent, ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _checkRead(); });
    return SingleChildScrollView(
      controller: controller,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: SelectableText(
        textContent,
        style: TextStyle(
          fontSize: 13.5,
          height: 1.6,
          color: Colors.grey.shade800,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
