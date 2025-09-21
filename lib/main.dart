import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:live_location_tracker/firebase_options.dart';
import 'package:live_location_tracker/widgets/custom_google_map.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const LiveLocationTrackerApp());
}

class LiveLocationTrackerApp extends StatelessWidget {
  const LiveLocationTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Live Location Tracker',
      theme: ThemeData(primarySwatch: Colors.blue, useMaterial3: true),
      home: const CustomGoogleMap(),
      debugShowCheckedModeBanner: false,
    );
  }
}
