import 'dart:math';
import 'holiday_tracker.dart';

class PredictionEngine {
  // Constants from Municipality Standards (as described in Kotlin spec)
  static const double wasteDensityPerSqm = 0.0217; // kg per sqm
  static const double truckCapacityKg = 5000.0;

  // Documented Service Areas (Estimated sqm for Barangay Balintawak)
  static final Map<String, double> purokAreas = {
    "Central (Purok 1)": 15000,
    "Purok Paraiso": 15000,
    "Riverside": 12000,
    "T.M. Kalaw Street": 8000,
    "Ayala Highway": 25000,
    "Brixton Homes": 20000,
    "El Pueblo": 18000,
    "San Nicolas": 10000,
    "Paraiso (Street Sweeping)": 12000,
    "Purok 2": 12000,
    "Purok 3": 14000,
  };

  /// 1. Waste Volume Prediction Logic
  /// Formula: Uses historical collection weight data if available, otherwise Area * Density * HolidayMultiplier
  static double predictWasteVolume(String purokName, {int stopCount = 0, DateTime? date, double? historicalAvgKg}) {
    double multiplier = HolidayTracker.getMultiplier(date ?? DateTime.now());

    if (historicalAvgKg != null && historicalAvgKg > 0) {
      // Historical data driven forecast
      double prediction = historicalAvgKg * multiplier;
      if (stopCount > 10) prediction *= 1.10;
      return prediction;
    }

    // Density/Area fallback calculation
    double area = purokAreas[purokName] ?? 10000.0;
    double prediction = area * wasteDensityPerSqm * multiplier;

    if (stopCount > 10) {
      prediction *= 1.15; // 15% increase for heavy areas
    }

    return prediction;
  }

  /// Predict Volume for the whole week
  static double predictWeeklyVolume(String purokName, {int avgStops = 0, double? historicalAvgKg}) {
    double total = 0;
    DateTime today = DateTime.now();
    for (int i = 0; i < 7; i++) {
      total += predictWasteVolume(
        purokName,
        stopCount: avgStops,
        date: today.add(Duration(days: i)),
        historicalAvgKg: historicalAvgKg,
      );
    }
    return total;
  }

  /// 2. Arrival Estimates (Simple Linear Regression)
  static double estimateArrivalTime(double distanceKm, List<double> recentSpeeds) {
    if (recentSpeeds.isEmpty) return distanceKm * 5.0; // Default 5 mins per km

    double avgSpeedKmh = recentSpeeds.reduce((a, b) => a + b) / recentSpeeds.length;
    if (avgSpeedKmh < 1.0) avgSpeedKmh = 5.0; // Avoid division by zero, min speed 5km/h

    double minutesPerKm = 60.0 / avgSpeedKmh;
    return distanceKm * minutesPerKm;
  }

  /// Haversine Distance Formula (Returns distance in kilometers)
  static double calculateHaversineDistance(double lat1, double lon1, double lat2, double lon2) {
    const double earthRadiusKm = 6371.0;
    double dLat = _degreesToRadians(lat2 - lat1);
    double dLon = _degreesToRadians(lon2 - lon1);

    double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degreesToRadians(lat1)) * cos(_degreesToRadians(lat2)) *
        sin(dLon / 2) * sin(dLon / 2);
    double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadiusKm * c;
  }

  /// Converts degrees to radians
  static double _degreesToRadians(double degrees) {
    return degrees * pi / 180.0;
  }

  /// Calculate live ETA in minutes taking into account distance, live speed, and remaining stops
  static double calculateLiveEtaMinutes(double distanceKm, double speedKmh, {int remainingStops = 0, double minsPerStop = 2.0}) {
    double safeSpeed = speedKmh > 3.0 ? speedKmh : 18.0; // Assume 18 km/h average if stationary or invalid
    double travelTimeMins = (distanceKm / safeSpeed) * 60.0;
    double stopBufferMins = remainingStops * minsPerStop;
    return travelTimeMins + stopBufferMins;
  }

  /// 3. Mean Absolute Error (MAE) for Prediction Accuracy
  static double calculateMAE(List<double> actuals, List<double> predicteds) {
    if (actuals.isEmpty || actuals.length != predicteds.length) return 0.0;

    double totalError = 0.0;
    for (int i = 0; i < actuals.length; i++) {
      totalError += (actuals[i] - predicteds[i]).abs();
    }

    return totalError / actuals.length;
  }

  /// 4. Accuracy Percentage based on MAE
  static double calculateAccuracyPercentage(double mae, double averageActual) {
    if (averageActual <= 0) return 100.0;
    double accuracy = (1 - (mae / averageActual)) * 100;
    return max(0, min(100, accuracy));
  }
}
