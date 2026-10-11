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

  String _termsContent = '';
  String _privacyContent = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadDocumentContents();
  }

  @override
  void dispose() {
    _tabController.dispose();
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
              tabs: const [
                Tab(text: "Terms & Conditions"),
                Tab(text: "Privacy Policy"),
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
                            _buildDocumentScrollArea(_termsContent),
                            _buildDocumentScrollArea(_privacyContent),
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
                  InkWell(
                    onTap: (_isLoading || _hasError || _isSubmitting)
                        ? null
                        : () => setState(() => _agreed = !_agreed),
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
                              onChanged: (_isLoading || _hasError || _isSubmitting)
                                  ? null
                                  : (v) => setState(() => _agreed = v ?? false),
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
                          onPressed: (_agreed && !_isLoading && !_hasError && !_isSubmitting)
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

  Widget _buildDocumentScrollArea(String textContent) {
    return SingleChildScrollView(
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
