import 'package:flutter/material.dart';
import 'package:firebase_database/firebase_database.dart';
import '../api/api_service.dart';
import '../utils/session_manager.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_snackbar.dart';
import '../services/service_area_service.dart';

class FileComplaintScreen extends StatefulWidget {
  const FileComplaintScreen({super.key});

  @override
  State<FileComplaintScreen> createState() => _FileComplaintScreenState();
}

class _FileComplaintScreenState extends State<FileComplaintScreen> {
  final ApiService _apiService = ApiService();
  final FirebaseDatabase _database = FirebaseDatabase.instance;
  final TextEditingController _descriptionController = TextEditingController();
  final TextEditingController _locationController = TextEditingController();
  String _selectedCategory = 'Uncollected Garbage';
  String _selectedPurok = 'Central (Purok 1)';
  bool _isLoading = false;

  final List<String> _categories = [
    'Uncollected Garbage',
    'Spilled Waste',
    'Driver Behavior',
    'Schedule Issue',
    'Other'
  ];

  final List<String> _purokOptions = ServiceAreaService.documentedAreaNames;

  @override
  void initState() {
    super.initState();
    SessionManager.getUser().then((user) {
      if (user != null && user.purok != null && user.purok!.isNotEmpty) {
        if (_purokOptions.contains(user.purok)) {
          setState(() => _selectedPurok = user.purok!);
        }
      }
    });
  }

  void _submitComplaint() async {
    final description = _descriptionController.text.trim();
    final location = _locationController.text.trim();
    if (description.isEmpty) {
      CustomSnackBar.show(context, message: "Please describe the issue", isError: true);
      return;
    }

    setState(() => _isLoading = true);
    final user = await SessionManager.getUser();
    
    try {
      final response = await _apiService.fileComplaint(
        user?.userId.toString() ?? "0",
        _selectedCategory,
        description,
        purok: _selectedPurok,
        location: location.isNotEmpty ? location : _selectedPurok,
      );

      if (response.data['success'] == true) {
        // TRIGGER APP NOTIFICATION FOR ADMIN VIA FIREBASE
        try {
          await _database.ref('notifications').push().set({
            'type': 'RESIDENT_COMPLAINT',
            'title': 'New Resident Complaint',
            'message': '${user?.name ?? 'A resident'} filed a complaint in $_selectedPurok: $_selectedCategory',
            'resident_id': user?.userId,
            'timestamp': ServerValue.timestamp,
            'isRead': false,
          });
        } catch (e) {
          debugPrint("Firebase notification error: $e");
        }

        if (!mounted) return;
        CustomSnackBar.show(context, message: "Complaint submitted successfully");
        Navigator.pop(context);
      } else {
        throw response.data['message'] ?? "Submission failed";
      }
    } catch (e) {
      if (!mounted) return;
      CustomSnackBar.show(context, message: "Error: $e", isError: true);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      body: SafeArea(
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: const BoxDecoration(color: Colors.white, boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(0, 2))]),
              child: Row(
                children: [
                  IconButton(icon: const Icon(Icons.arrow_back, color: Color(0xFF333333)), onPressed: () => Navigator.pop(context)),
                  const SizedBox(width: 8),
                  const Text("File a Complaint", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF1A1A1A))),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Select Category
                    const Text("Select Category", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF757575))),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE0E0E0))),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedCategory,
                          isExpanded: true,
                          items: _categories.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                          onChanged: (val) => setState(() => _selectedCategory = val!),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Purok Selection
                    const Text("Purok / Area", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF757575))),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE0E0E0))),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _selectedPurok,
                          isExpanded: true,
                          items: _purokOptions.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
                          onChanged: (val) => setState(() => _selectedPurok = val!),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Specific Location / Landmark
                    const Text("Specific Location / Landmark", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF757575))),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE0E0E0))),
                      child: TextField(
                        controller: _locationController,
                        decoration: const InputDecoration(
                          hintText: "e.g., Near Barangay Hall, Block 3 Lot 5...",
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Description
                    const Text("Description / Details", style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF757575))),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(color: const Color(0xFFF5F5F5), borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE0E0E0))),
                      child: TextField(
                        controller: _descriptionController,
                        maxLines: 5,
                        decoration: const InputDecoration(
                          hintText: "Provide details about your complaint...",
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.all(16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Submit Button
                    ElevatedButton(
                      onPressed: _isLoading ? null : _submitComplaint,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        minimumSize: const Size(double.infinity, 56),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text("Submit Complaint", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
