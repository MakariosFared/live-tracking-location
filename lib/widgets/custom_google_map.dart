import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class CustomGoogleMap extends StatefulWidget {
  const CustomGoogleMap({super.key});

  @override
  State<CustomGoogleMap> createState() => _CustomGoogleMapState();
}

class _CustomGoogleMapState extends State<CustomGoogleMap> {
  // Firebase
  late DatabaseReference _dbRef;
  late DatabaseReference _ridesRef;
  late DatabaseReference _driversRef;
  late DatabaseReference _ridersRef;

  // User Management
  bool _isDriverMode = false;
  String _userId = '';
  String _currentRideId = '';
  String _userName = '';

  // Ride Management
  bool _isTrackingActive = false;
  bool _isRideActive = false;
  String _rideStatus =
      'idle'; // idle, requested, accepted, started, completed, cancelled

  // Locations
  LatLng? _userLocation;
  LatLng? _driverLocation;
  LatLng? _riderLocation;
  LatLng? _pickupLocation;
  LatLng? _destinationLocation;

  // Distance and Route
  double _distanceBetween = 0.0;
  double _estimatedFare = 0.0;
  List<LatLng> _routePoints = [];

  // Google Directions API
  static const String _googleDirectionsApiKey =
      'AIzaSyCCOlStSbMeZ6qNoHO9Dz0KODmfpgWcXTQ';
  static const String _googleDirectionsUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  // Streams and Timers
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<DatabaseEvent>? _rideStream;
  StreamSubscription<DatabaseEvent>? _driverLocationStream;
  StreamSubscription<DatabaseEvent>? _rideRequestStream;

  // Debouncing for API calls
  Timer? _routeUpdateTimer;

  // Map
  GoogleMapController? googleMapController;
  Set<Marker> markers = {};
  Set<Polyline> polylines = {};

  late CameraPosition initialCameraPosition;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  void _initializeApp() {
    initialCameraPosition = const CameraPosition(
      zoom: 16,
      target: LatLng(31.187084851056554, 29.928110526889437),
    );

    // Initialize Firebase references
    _dbRef = FirebaseDatabase.instance.ref();
    _ridesRef = _dbRef.child('rides');
    _driversRef = _dbRef.child('drivers');
    _ridersRef = _dbRef.child('riders');

    // Generate unique user ID
    _userId = DateTime.now().millisecondsSinceEpoch.toString();
    _userName = _isDriverMode
        ? 'Driver_${_userId.substring(_userId.length - 4)}'
        : 'Rider_${_userId.substring(_userId.length - 4)}';

    _requestLocationPermissions();
    _registerUser();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _rideStream?.cancel();
    _driverLocationStream?.cancel();
    _rideRequestStream?.cancel();
    _routeUpdateTimer?.cancel();
    _unregisterUser();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isDriverMode ? 'Driver: $_userName' : 'Rider: $_userName'),
        backgroundColor: _isDriverMode ? Colors.green : Colors.blue,
        actions: [
          if (_distanceBetween > 0)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Center(
                child: Text(
                  '${_distanceBetween.toStringAsFixed(1)} m',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          if (_estimatedFare > 0)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Center(
                child: Text(
                  '\$${_estimatedFare.toStringAsFixed(2)}',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
        ],
      ),
      body: Stack(
        children: [
          GoogleMap(
            markers: markers,
            polylines: polylines,
            zoomControlsEnabled: false,
            myLocationEnabled: true,
            myLocationButtonEnabled: false,
            onMapCreated: (controller) {
              googleMapController = controller;
              initMapStyle();
            },
            onTap: _onMapTap,
            initialCameraPosition: initialCameraPosition,
          ),

          // Mode toggle button
          Positioned(
            top: 20,
            right: 20,
            child: FloatingActionButton(
              onPressed: _toggleMode,
              backgroundColor: _isDriverMode ? Colors.green : Colors.blue,
              child: Icon(_isDriverMode ? Icons.drive_eta : Icons.person),
              tooltip: _isDriverMode
                  ? 'Switch to Rider Mode'
                  : 'Switch to Driver Mode',
            ),
          ),

          // GPS Location button
          Positioned(
            bottom: 120,
            right: 20,
            child: FloatingActionButton(
              onPressed: _getCurrentLocation,
              backgroundColor: Colors.orange,
              child: const Icon(Icons.my_location),
              tooltip: 'Get Current Location',
            ),
          ),

          // Driver-specific buttons
          if (_isDriverMode) ...[
            // Start/Stop tracking button
            Positioned(
              bottom: 200,
              right: 20,
              child: FloatingActionButton(
                onPressed: _toggleTracking,
                backgroundColor: _isTrackingActive ? Colors.red : Colors.green,
                child: Icon(_isTrackingActive ? Icons.stop : Icons.play_arrow),
                tooltip: _isTrackingActive ? 'Stop Tracking' : 'Start Tracking',
              ),
            ),
            // Accept ride button (when ride is requested)
            if (_rideStatus == 'requested')
              Positioned(
                bottom: 280,
                right: 20,
                child: FloatingActionButton.extended(
                  onPressed: _acceptRide,
                  backgroundColor: Colors.green,
                  icon: const Icon(Icons.check),
                  label: const Text('Accept Ride'),
                  tooltip: 'Accept this ride request',
                ),
              ),
            // Start ride button (when ride is accepted)
            if (_rideStatus == 'accepted')
              Positioned(
                bottom: 280,
                right: 20,
                child: FloatingActionButton.extended(
                  onPressed: _startRide,
                  backgroundColor: Colors.blue,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Ride'),
                  tooltip: 'Start the ride',
                ),
              ),
            // Complete ride button (when ride is started)
            if (_rideStatus == 'started')
              Positioned(
                bottom: 280,
                right: 20,
                child: FloatingActionButton.extended(
                  onPressed: _completeRide,
                  backgroundColor: Colors.green,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Complete Ride'),
                  tooltip: 'Mark ride as completed',
                ),
              ),
          ],

          // Rider-specific buttons
          if (!_isDriverMode) ...[
            // Set pickup location button
            Positioned(
              bottom: 200,
              right: 20,
              child: FloatingActionButton(
                onPressed: _setPickupLocation,
                backgroundColor: Colors.purple,
                child: const Icon(Icons.location_on),
                tooltip: 'Set Pickup Location',
              ),
            ),
            // Set destination button
            Positioned(
              bottom: 280,
              right: 20,
              child: FloatingActionButton(
                onPressed: _setDestinationLocation,
                backgroundColor: Colors.red,
                child: const Icon(Icons.place),
                tooltip: 'Set Destination',
              ),
            ),
            // Request ride button
            if (_pickupLocation != null &&
                _destinationLocation != null &&
                _rideStatus == 'idle')
              Positioned(
                bottom: 360,
                right: 20,
                child: FloatingActionButton.extended(
                  onPressed: _requestRide,
                  backgroundColor: Colors.blue,
                  icon: const Icon(Icons.local_taxi),
                  label: const Text('Request Ride'),
                  tooltip: 'Request a ride',
                ),
              ),
            // Cancel ride button
            if (_rideStatus == 'requested' || _rideStatus == 'accepted')
              Positioned(
                bottom: 360,
                right: 20,
                child: FloatingActionButton.extended(
                  onPressed: _cancelRide,
                  backgroundColor: Colors.red,
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel Ride'),
                  tooltip: 'Cancel current ride',
                ),
              ),
          ],

          // Status and ride info
          Positioned(
            bottom: 20,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _getStatusMessage(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_currentRideId.isNotEmpty)
                    Text(
                      'Ride ID: ${_currentRideId.substring(_currentRideId.length - 6)}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  if (_estimatedFare > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Estimated Fare: \$${_estimatedFare.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: Colors.green,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                  if (_distanceBetween > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Distance: ${_distanceBetween.toStringAsFixed(1)}m',
                      style: const TextStyle(
                        color: Colors.orange,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void initMapStyle() async {
    try {
      var nightMapStyle = await DefaultAssetBundle.of(
        context,
      ).loadString('assets/map_syles/night_map_style.json');
      googleMapController!.setMapStyle(nightMapStyle);
    } catch (e) {
      print('Could not load map style: $e');
    }
  }

  void _toggleMode() {
    setState(() {
      _isDriverMode = !_isDriverMode;
      _isTrackingActive = false;
      _isRideActive = false;
      _rideStatus = 'idle';
      _currentRideId = '';
      _routePoints.clear();
      _pickupLocation = null;
      _destinationLocation = null;
      _riderLocation = null;
      _driverLocation = null;
      _estimatedFare = 0.0;
      _distanceBetween = 0.0;
    });

    // Cancel previous streams
    _positionStream?.cancel();
    _rideStream?.cancel();
    _driverLocationStream?.cancel();
    _rideRequestStream?.cancel();

    // Update user registration
    _userName = _isDriverMode
        ? 'Driver_${_userId.substring(_userId.length - 4)}'
        : 'Rider_${_userId.substring(_userId.length - 4)}';
    _registerUser();

    if (_isDriverMode) {
      _startDriverMode();
    } else {
      _startRiderMode();
    }
  }

  // ---------------- USER REGISTRATION ----------------
  void _registerUser() {
    if (_isDriverMode) {
      _driversRef.child(_userId).set({
        'name': _userName,
        'isOnline': true,
        'isAvailable': true,
        'currentRideId': '',
        'location': _userLocation != null
            ? {'lat': _userLocation!.latitude, 'lng': _userLocation!.longitude}
            : null,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
      });
    } else {
      _ridersRef.child(_userId).set({
        'name': _userName,
        'isOnline': true,
        'currentRideId': '',
        'location': _userLocation != null
            ? {'lat': _userLocation!.latitude, 'lng': _userLocation!.longitude}
            : null,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  void _unregisterUser() {
    if (_isDriverMode) {
      _driversRef.child(_userId).update({
        'isOnline': false,
        'isAvailable': false,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
      });
    } else {
      _ridersRef.child(_userId).update({
        'isOnline': false,
        'lastSeen': DateTime.now().millisecondsSinceEpoch,
      });
    }
  }

  // ---------------- DRIVER MODE ----------------
  void _startDriverMode() {
    // Listen for ride requests
    _rideRequestStream = _ridesRef.onChildAdded.listen((event) {
      final rideData = Map<String, dynamic>.from(event.snapshot.value as Map);
      if (rideData['status'] == 'requested' && rideData['driverId'] == null) {
        _showRideRequestDialog(rideData, event.snapshot.key!);
      }
    });
  }

  void _showRideRequestDialog(Map<String, dynamic> rideData, String rideId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New Ride Request'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'From: ${rideData['pickup']['address'] ?? 'Unknown location'}',
            ),
            Text(
              'To: ${rideData['destination']['address'] ?? 'Unknown location'}',
            ),
            Text(
              'Fare: \$${rideData['estimatedFare']?.toStringAsFixed(2) ?? '0.00'}',
            ),
            Text(
              'Distance: ${rideData['distance']?.toStringAsFixed(1) ?? '0'} km',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _rejectRide(rideId);
            },
            child: const Text('Reject'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              _acceptRideRequest(rideId);
            },
            child: const Text('Accept'),
          ),
        ],
      ),
    );
  }

  void _acceptRideRequest(String rideId) {
    setState(() {
      _currentRideId = rideId;
      _rideStatus = 'accepted';
    });

    _ridesRef.child(rideId).update({
      'status': 'accepted',
      'driverId': _userId,
      'driverName': _userName,
      'acceptedAt': DateTime.now().millisecondsSinceEpoch,
    });

    _driversRef.child(_userId).update({
      'isAvailable': false,
      'currentRideId': rideId,
    });

    _loadRideData(rideId);
    _listenToRideUpdates();
    _showSnackBar('Ride accepted!');
  }

  void _rejectRide(String rideId) {
    _ridesRef.child(rideId).child('rejectedDrivers').child(_userId).set(true);
  }

  void _acceptRide() {
    if (_currentRideId.isEmpty) return;
    _startRide();
  }

  void _startRide() {
    if (_currentRideId.isEmpty) return;

    setState(() {
      _rideStatus = 'started';
      _isRideActive = true;
    });

    _ridesRef.child(_currentRideId).update({
      'status': 'started',
      'startedAt': DateTime.now().millisecondsSinceEpoch,
    });

    _showSnackBar('Ride started!');
  }

  void _completeRide() {
    if (_currentRideId.isEmpty) return;

    setState(() {
      _rideStatus = 'completed';
      _isRideActive = false;
      _isTrackingActive = false;
    });

    // Clean up streams
    _positionStream?.cancel();
    _rideStream?.cancel();
    _driverLocationStream?.cancel();
    _rideRequestStream?.cancel();
    _routeUpdateTimer?.cancel();

    _ridesRef.child(_currentRideId).update({
      'status': 'completed',
      'completedAt': DateTime.now().millisecondsSinceEpoch,
    });

    _driversRef.child(_userId).update({
      'isAvailable': true,
      'currentRideId': '',
    });

    setState(() {
      _currentRideId = '';
      _rideStatus = 'idle';
      _pickupLocation = null;
      _destinationLocation = null;
      _riderLocation = null;
      _driverLocation = null;
      _routePoints.clear();
      _estimatedFare = 0.0;
      _distanceBetween = 0.0;
    });

    _showSnackBar('Ride completed!');
  }

  void _toggleTracking() {
    setState(() {
      _isTrackingActive = !_isTrackingActive;
    });

    if (_isTrackingActive) {
      _startLocationTracking();
    } else {
      _stopLocationTracking();
    }
  }

  void _startLocationTracking() {
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 10, // Increased from 3 to 10 meters
          ),
        ).listen(
          (position) async {
            try {
              // Check location accuracy
              if (position.accuracy > 100) {
                _showSnackBar('Poor GPS signal. Please move to open area.');
                return;
              }

              setState(() {
                _driverLocation = LatLng(position.latitude, position.longitude);
                _userLocation = _driverLocation;
              });

              // Update driver location in Firebase with error handling
              try {
                await _driversRef.child(_userId).update({
                  'location': {
                    'lat': _driverLocation!.latitude,
                    'lng': _driverLocation!.longitude,
                  },
                  'lastSeen': ServerValue.timestamp,
                });
              } catch (e) {
                print('Error updating driver location: $e');
                _showSnackBar('Failed to update location');
              }

              // Update ride location if active
              if (_isRideActive && _currentRideId.isNotEmpty) {
                try {
                  await _ridesRef
                      .child(_currentRideId)
                      .child('driverLocation')
                      .set({
                        'lat': _driverLocation!.latitude,
                        'lng': _driverLocation!.longitude,
                        'timestamp': ServerValue.timestamp,
                      });
                } catch (e) {
                  print('Error updating ride location: $e');
                }
              }

              _updateMarkers();
              _calculateDistance();

              // Get real routes if needed (with debouncing)
              if (_isRideActive && _pickupLocation != null) {
                if (_rideStatus == 'accepted') {
                  // Driver to pickup location
                  _getRouteDirectionsWithDebounce(
                    _driverLocation!,
                    _pickupLocation!,
                  );
                } else if (_rideStatus == 'started' &&
                    _destinationLocation != null) {
                  // Driver to destination location
                  _getRouteDirectionsWithDebounce(
                    _driverLocation!,
                    _destinationLocation!,
                  );
                }
              }
            } catch (e) {
              print('Error in location tracking: $e');
              _showSnackBar('Location tracking error');
            }
          },
          onError: (error) {
            print('Location stream error: $error');
            _showSnackBar('GPS error: ${error.toString()}');
          },
        );
  }

  void _stopLocationTracking() {
    _positionStream?.cancel();
    _driversRef.child(_userId).update({'isAvailable': false});
    _showSnackBar('Location tracking stopped');
  }

  // ---------------- RIDER MODE ----------------
  void _startRiderMode() {
    // Cancel any existing stream first
    _driverLocationStream?.cancel();

    // Start rider location tracking if ride is active
    if (_currentRideId.isNotEmpty && _rideStatus != 'idle') {
      _startRiderLocationTracking();
    }

    // Listen to Firebase for driver location
    _driverLocationStream = _ridesRef
        .child(_currentRideId)
        .child('driverLocation')
        .onValue
        .listen((event) {
          if (event.snapshot.exists) {
            final data = Map<String, dynamic>.from(event.snapshot.value as Map);
            setState(() {
              _driverLocation = LatLng(data['lat'], data['lng']);
            });
            _updateMarkers();
            _calculateDistance();

            // Get route from driver to pickup (not to rider)
            if (_pickupLocation != null && _driverLocation != null) {
              _getRouteDirectionsWithDebounce(
                _driverLocation!,
                _pickupLocation!,
              );
            }

            // Move camera to follow driver if ride is active
            if (_rideStatus == 'started' && googleMapController != null) {
              googleMapController!.animateCamera(
                CameraUpdate.newLatLng(_driverLocation!),
              );
            }
          }
        });
  }

  void _startRiderLocationTracking() {
    _positionStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 5, // Update every 5 meters
          ),
        ).listen(
          (position) async {
            try {
              // Check location accuracy
              if (position.accuracy > 50) {
                return; // Skip poor accuracy updates
              }

              setState(() {
                _riderLocation = LatLng(position.latitude, position.longitude);
                _userLocation = _riderLocation;
              });

              // Update rider location in Firebase
              try {
                await _ridesRef
                    .child(_currentRideId)
                    .child('riderLocation')
                    .set({
                      'lat': _riderLocation!.latitude,
                      'lng': _riderLocation!.longitude,
                      'timestamp': ServerValue.timestamp,
                    });

                await _ridersRef.child(_userId).update({
                  'location': {
                    'lat': _riderLocation!.latitude,
                    'lng': _riderLocation!.longitude,
                  },
                  'lastSeen': ServerValue.timestamp,
                });
              } catch (e) {
                print('Error updating rider location: $e');
              }

              _updateMarkers();
              _calculateDistance();
            } catch (e) {
              print('Error in rider location tracking: $e');
            }
          },
          onError: (error) {
            print('Rider location stream error: $error');
          },
        );
  }

  void _requestRide() async {
    if (_pickupLocation == null || _destinationLocation == null) {
      _showSnackBar('Please set both pickup and destination locations');
      return;
    }

    if (_riderLocation == null) {
      _showSnackBar('Please set your current location first');
      return;
    }

    setState(() {
      _currentRideId = DateTime.now().millisecondsSinceEpoch.toString();
      _rideStatus = 'requested';
    });

    try {
      // Calculate distance and fare
      double distance =
          Geolocator.distanceBetween(
            _pickupLocation!.latitude,
            _pickupLocation!.longitude,
            _destinationLocation!.latitude,
            _destinationLocation!.longitude,
          ) /
          1000; // Convert to km

      _estimatedFare = distance * 2.5; // $2.5 per km

      await _ridesRef.child(_currentRideId).set({
        'riderId': _userId,
        'riderName': _userName,
        'pickup': {
          'lat': _pickupLocation!.latitude,
          'lng': _pickupLocation!.longitude,
          'address': 'Pickup Location',
        },
        'destination': {
          'lat': _destinationLocation!.latitude,
          'lng': _destinationLocation!.longitude,
          'address': 'Destination Location',
        },
        'status': 'requested',
        'distance': distance,
        'estimatedFare': _estimatedFare,
        'requestedAt': ServerValue.timestamp,
        'riderLocation': {
          'lat': _riderLocation!.latitude,
          'lng': _riderLocation!.longitude,
          'timestamp': ServerValue.timestamp,
        },
      });

      await _ridersRef.child(_userId).update({
        'currentRideId': _currentRideId,
        'location': {
          'lat': _riderLocation!.latitude,
          'lng': _riderLocation!.longitude,
        },
      });

      _listenToRideUpdates();
      _showSnackBar('Ride request sent! Looking for drivers...');
    } catch (e) {
      print('Error requesting ride: $e');
      _showSnackBar('Failed to request ride. Please try again.');
      setState(() {
        _currentRideId = '';
        _rideStatus = 'idle';
      });
    }
  }

  void _cancelRide() async {
    if (_currentRideId.isEmpty) return;

    try {
      await _ridesRef.child(_currentRideId).update({
        'status': 'cancelled',
        'cancelledAt': DateTime.now().millisecondsSinceEpoch,
      });

      await _ridersRef.child(_userId).update({'currentRideId': ''});

      // Clean up streams
      _positionStream?.cancel();
      _rideStream?.cancel();
      _driverLocationStream?.cancel();
      _rideRequestStream?.cancel();
      _routeUpdateTimer?.cancel();

      setState(() {
        _currentRideId = '';
        _rideStatus = 'idle';
        _estimatedFare = 0.0;
        _pickupLocation = null;
        _destinationLocation = null;
        _riderLocation = null;
        _driverLocation = null;
        _routePoints.clear();
        _distanceBetween = 0.0;
        _isRideActive = false;
        _isTrackingActive = false;
      });

      _showSnackBar('Ride cancelled');
    } catch (e) {
      print('Error cancelling ride: $e');
      _showSnackBar('Failed to cancel ride. Please try again.');
    }
  }

  void _listenToRideUpdates() {
    _rideStream?.cancel();

    _rideStream = _ridesRef.child(_currentRideId).onValue.listen((event) {
      if (event.snapshot.exists) {
        final rideData = Map<String, dynamic>.from(event.snapshot.value as Map);
        final String newStatus = rideData['status'] ?? 'idle';

        setState(() {
          _rideStatus = newStatus;
        });

        if (newStatus == 'accepted') {
          if (_isDriverMode) {
            // Driver mode: Load ride data and start listening to rider location
            _loadRideData(_currentRideId);
            _listenToRiderLocation();
          } else {
            // Rider mode: Start tracking rider location and listening to driver
            _showSnackBar('Driver accepted your ride!');
            _startRiderMode();

            if (rideData['driverLocation'] != null) {
              final driverLocData = rideData['driverLocation'];
              _driverLocation = LatLng(
                driverLocData['lat'],
                driverLocData['lng'],
              );

              if (_pickupLocation != null) {
                _getRouteDirectionsWithDebounce(
                  _driverLocation!,
                  _pickupLocation!,
                );
              }
            }
          }
        } else if (newStatus == 'started') {
          _showSnackBar('Driver is on the way!');
        } else if (newStatus == 'completed') {
          _showSnackBar('Ride completed! Thank you for using our service.');

          // Clean up streams
          _positionStream?.cancel();
          _rideStream?.cancel();
          _driverLocationStream?.cancel();
          _rideRequestStream?.cancel();
          _routeUpdateTimer?.cancel();

          setState(() {
            _currentRideId = '';
            _rideStatus = 'idle';
            _pickupLocation = null;
            _destinationLocation = null;
            _riderLocation = null;
            _driverLocation = null;
            _routePoints.clear();
            _estimatedFare = 0.0;
            _distanceBetween = 0.0;
            _isRideActive = false;
            _isTrackingActive = false;
          });
        }
      }
    });
  }

  // ---------------- LOCATION METHODS ----------------
  Future<void> _requestLocationPermissions() async {
    try {
      // Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showSnackBar('Location services are disabled. Please enable GPS.');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        _showPermissionDialog(
          'Location Permission Required',
          'Location permissions are permanently denied. Please enable location permission in settings to use GPS features.',
        );
        return;
      }

      if (permission == LocationPermission.denied) {
        _showSnackBar(
          'Location permissions denied. You can still tap the map to set location.',
        );
        return;
      }

      if (permission == LocationPermission.whileInUse ||
          permission == LocationPermission.always) {
        _showSnackBar(
          'Location permissions granted! Tap GPS button or map to set location.',
        );
      }
    } catch (e) {
      print('Permission error: $e');
      _showSnackBar(
        'Location service error. You can still tap the map to set location.',
      );
    }
  }

  void _showPermissionDialog(String title, String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Geolocator.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  Future<void> _getCurrentLocation() async {
    try {
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );

      setState(() {
        _userLocation = LatLng(position.latitude, position.longitude);

        if (_isDriverMode) {
          _driverLocation = _userLocation;
        } else {
          _riderLocation = _userLocation;
        }
      });

      _updateMarkers();
      _moveCameraToLocation(_userLocation!);
      _updateUserLocation();
      _showSnackBar('Location set successfully!');
    } catch (e) {
      print('Error getting location: $e');
      _showSnackBar(
        'GPS not available. Please tap the map to set your location.',
      );
    }
  }

  void _onMapTap(LatLng position) {
    setState(() {
      _userLocation = position;

      if (_isDriverMode) {
        _driverLocation = position;
        if (_isTrackingActive) {
          _driversRef.child(_userId).update({
            'location': {
              'lat': _driverLocation!.latitude,
              'lng': _driverLocation!.longitude,
            },
          });
        }
      } else {
        _riderLocation = position;
        _ridersRef.child(_userId).update({
          'location': {
            'lat': _riderLocation!.latitude,
            'lng': _riderLocation!.longitude,
          },
        });
      }
    });

    _updateMarkers();
    _moveCameraToLocation(position);
    _showSnackBar('Location set by tapping map');
  }

  void _updateUserLocation() {
    if (_userLocation != null) {
      if (_isDriverMode) {
        _driversRef.child(_userId).update({
          'location': {
            'lat': _userLocation!.latitude,
            'lng': _userLocation!.longitude,
          },
          'lastSeen': DateTime.now().millisecondsSinceEpoch,
        });
      } else {
        _ridersRef.child(_userId).update({
          'location': {
            'lat': _userLocation!.latitude,
            'lng': _userLocation!.longitude,
          },
          'lastSeen': DateTime.now().millisecondsSinceEpoch,
        });
      }
    }
  }

  void _setPickupLocation() {
    if (_riderLocation == null) {
      _showSnackBar('Please set your location first');
      return;
    }

    setState(() {
      _pickupLocation = _riderLocation;
    });

    _updateMarkers();
    _showSnackBar('Pickup location set!');
  }

  void _setDestinationLocation() {
    if (_riderLocation == null) {
      _showSnackBar('Please set your location first');
      return;
    }

    setState(() {
      _destinationLocation = _riderLocation;
    });

    _updateMarkers();
    _showSnackBar('Destination location set!');
  }

  // ---------------- MAP UPDATES ----------------
  void _updateMarkers() {
    markers.clear();

    if (_isDriverMode) {
      // Driver mode: Show driver location
      if (_driverLocation != null) {
        markers.add(
          Marker(
            markerId: const MarkerId('driver'),
            position: _driverLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueGreen,
            ),
            infoWindow: const InfoWindow(title: 'Your Location'),
          ),
        );
      }

      // Show rider location if available
      if (_riderLocation != null) {
        markers.add(
          Marker(
            markerId: const MarkerId('rider'),
            position: _riderLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueBlue,
            ),
            infoWindow: const InfoWindow(title: 'Rider Location'),
          ),
        );
      }

      // Show pickup location if set
      if (_pickupLocation != null) {
        markers.add(
          Marker(
            markerId: const MarkerId('pickup'),
            position: _pickupLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueViolet,
            ),
            infoWindow: const InfoWindow(title: 'Pickup Location'),
          ),
        );
      }

      // Show destination if set
      if (_destinationLocation != null) {
        markers.add(
          Marker(
            markerId: const MarkerId('destination'),
            position: _destinationLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            infoWindow: const InfoWindow(title: 'Destination'),
          ),
        );
      }
    } else {
      // Rider mode: Show rider and driver locations
      if (_riderLocation != null) {
        markers.add(
          Marker(
            markerId: const MarkerId('rider'),
            position: _riderLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueRed,
            ),
            infoWindow: const InfoWindow(title: 'Your Location'),
          ),
        );
      }

      if (_driverLocation != null) {
        markers.add(
          Marker(
            markerId: const MarkerId('driver'),
            position: _driverLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueBlue,
            ),
            infoWindow: const InfoWindow(title: 'Driver Location'),
          ),
        );
      }

      // Show pickup location if set
      if (_pickupLocation != null) {
        markers.add(
          Marker(
            markerId: const MarkerId('pickup'),
            position: _pickupLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueViolet,
            ),
            infoWindow: const InfoWindow(title: 'Pickup Location'),
          ),
        );
      }

      // Show destination if set
      if (_destinationLocation != null) {
        markers.add(
          Marker(
            markerId: const MarkerId('destination'),
            position: _destinationLocation!,
            icon: BitmapDescriptor.defaultMarkerWithHue(
              BitmapDescriptor.hueOrange,
            ),
            infoWindow: const InfoWindow(title: 'Destination'),
          ),
        );
      }
    }

    _updatePolylines();
  }

  void _updatePolylines() {
    polylines.clear();

    if (_isDriverMode && _driverLocation != null) {
      // Driver to pickup route - use real route if available
      if (_pickupLocation != null && _rideStatus == 'accepted') {
        if (_routePoints.isNotEmpty) {
          polylines.add(
            Polyline(
              polylineId: const PolylineId('driver_to_pickup'),
              points: _routePoints,
              color: Colors.green,
              width: 4,
            ),
          );
        } else {
          // Fallback to straight line
          polylines.add(
            Polyline(
              polylineId: const PolylineId('driver_to_pickup'),
              points: [_driverLocation!, _pickupLocation!],
              color: Colors.green,
              width: 4,
            ),
          );
        }
      }

      // Driver to destination route (when ride is started)
      if (_destinationLocation != null && _rideStatus == 'started') {
        if (_routePoints.isNotEmpty) {
          polylines.add(
            Polyline(
              polylineId: const PolylineId('driver_to_destination'),
              points: _routePoints,
              color: Colors.blue,
              width: 4,
            ),
          );
        } else {
          // Fallback to straight line
          polylines.add(
            Polyline(
              polylineId: const PolylineId('driver_to_destination'),
              points: [_driverLocation!, _destinationLocation!],
              color: Colors.blue,
              width: 4,
            ),
          );
        }
      }

      // Show rider location as dashed line (for reference)
      if (_riderLocation != null && _rideStatus == 'accepted') {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('driver_to_rider'),
            points: [_driverLocation!, _riderLocation!],
            color: Colors.orange,
            width: 2,
            patterns: [PatternItem.dash(10), PatternItem.gap(5)],
          ),
        );
      }
    } else if (!_isDriverMode &&
        _riderLocation != null &&
        _driverLocation != null) {
      // Rider sees route from driver to pickup (not to rider)
      if (_pickupLocation != null && _routePoints.isNotEmpty) {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('driver_to_pickup'),
            points: _routePoints,
            color: Colors.green,
            width: 3,
          ),
        );
      } else if (_pickupLocation != null) {
        // Fallback to straight line
        polylines.add(
          Polyline(
            polylineId: const PolylineId('driver_to_pickup'),
            points: [_driverLocation!, _pickupLocation!],
            color: Colors.green,
            width: 3,
          ),
        );
      }

      // Show pickup to destination route
      if (_destinationLocation != null && _pickupLocation != null) {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('pickup_to_destination'),
            points: [_pickupLocation!, _destinationLocation!],
            color: Colors.blue,
            width: 2,
            patterns: [PatternItem.dash(15), PatternItem.gap(8)],
          ),
        );
      }
    }
  }

  void _moveCameraToLocation(LatLng location) {
    googleMapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: location, zoom: 16),
      ),
    );
  }

  // ---------------- DISTANCE CALCULATION ----------------
  void _calculateDistance() {
    if (_riderLocation != null && _driverLocation != null) {
      _distanceBetween = Geolocator.distanceBetween(
        _riderLocation!.latitude,
        _riderLocation!.longitude,
        _driverLocation!.latitude,
        _driverLocation!.longitude,
      );
      setState(() {});
    }
  }

  // ---------------- STATUS MESSAGE ----------------
  String _getStatusMessage() {
    if (_isDriverMode) {
      switch (_rideStatus) {
        case 'idle':
          return _isTrackingActive
              ? 'Online - Waiting for rides'
              : 'Offline - Start tracking to receive rides';
        case 'requested':
          return 'Ride request received - Check notification';
        case 'accepted':
          return 'Ride accepted - Start when ready';
        case 'started':
          return 'Ride in progress - Head to pickup location';
        case 'completed':
          return 'Ride completed - Available for new rides';
        default:
          return 'Driver mode';
      }
    } else {
      switch (_rideStatus) {
        case 'idle':
          return 'Set pickup and destination to request a ride';
        case 'requested':
          return 'Looking for drivers...';
        case 'accepted':
          return 'Driver accepted - Waiting for pickup';
        case 'started':
          return 'Driver is on the way!';
        case 'completed':
          return 'Ride completed - Thank you!';
        default:
          return 'Rider mode';
      }
    }
  }

  // ---------------- DEBOUNCING FOR API CALLS ----------------
  void _getRouteDirectionsWithDebounce(LatLng origin, LatLng destination) {
    // Cancel previous timer
    _routeUpdateTimer?.cancel();

    // Set new timer to debounce API calls
    _routeUpdateTimer = Timer(const Duration(seconds: 2), () {
      _getRouteDirections(origin, destination);
    });
  }

  // ---------------- GOOGLE DIRECTIONS API ----------------
  Future<void> _getRouteDirections(LatLng origin, LatLng destination) async {
    try {
      final url = Uri.parse(
        '$_googleDirectionsUrl?'
        'origin=${origin.latitude},${origin.longitude}'
        '&destination=${destination.latitude},${destination.longitude}'
        '&key=$_googleDirectionsApiKey',
      );

      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);

        if (data['status'] == 'OK' && data['routes'].isNotEmpty) {
          final route = data['routes'][0];
          final polyline = route['overview_polyline']['points'];

          setState(() {
            _routePoints = _decodePolyline(polyline);
            _updatePolylines();
          });
        } else {
          print('Directions API error: ${data['status']}');
          // Fallback to straight line
          setState(() {
            _routePoints = [origin, destination];
            _updatePolylines();
          });
        }
      } else {
        print('HTTP error: ${response.statusCode}');
        // Fallback to straight line
        setState(() {
          _routePoints = [origin, destination];
          _updatePolylines();
        });
      }
    } catch (e) {
      print('Error getting directions: $e');
      // Fallback to straight line
      setState(() {
        _routePoints = [origin, destination];
        _updatePolylines();
      });
    }
  }

  List<LatLng> _decodePolyline(String polyline) {
    List<LatLng> points = [];
    int index = 0;
    int lat = 0;
    int lng = 0;

    while (index < polyline.length) {
      int b, shift = 0, result = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        b = polyline.codeUnitAt(index++) - 63;
        result |= (b & 0x1f) << shift;
        shift += 5;
      } while (b >= 0x20);
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
      lng += dlng;

      points.add(LatLng(lat / 1e5, lng / 1e5));
    }

    return points;
  }

  // ---------------- RIDE DATA LOADING ----------------
  void _loadRideData(String rideId) {
    _ridesRef.child(rideId).once().then((event) {
      if (event.snapshot.exists) {
        final rideData = Map<String, dynamic>.from(event.snapshot.value as Map);

        setState(() {
          // Load pickup location
          if (rideData['pickup'] != null) {
            final pickupData = rideData['pickup'];
            _pickupLocation = LatLng(pickupData['lat'], pickupData['lng']);
          }

          // Load destination location
          if (rideData['destination'] != null) {
            final destData = rideData['destination'];
            _destinationLocation = LatLng(destData['lat'], destData['lng']);
          }

          // Load estimated fare
          if (rideData['estimatedFare'] != null) {
            _estimatedFare = rideData['estimatedFare'].toDouble();
          }
        });

        _updateMarkers();

        // Get route to pickup location
        if (_driverLocation != null && _pickupLocation != null) {
          _getRouteDirections(_driverLocation!, _pickupLocation!);
        }
      }
    });
  }

  void _listenToRiderLocation() {
    _rideRequestStream?.cancel();

    _rideRequestStream = _ridesRef
        .child(_currentRideId)
        .child('riderLocation')
        .onValue
        .listen((event) {
          if (event.snapshot.exists) {
            final data = Map<String, dynamic>.from(event.snapshot.value as Map);
            setState(() {
              _riderLocation = LatLng(data['lat'], data['lng']);
            });
            _updateMarkers();
            _calculateDistance();

            // Get route to pickup location (not to rider)
            if (_rideStatus == 'accepted' &&
                _driverLocation != null &&
                _pickupLocation != null) {
              _getRouteDirectionsWithDebounce(
                _driverLocation!,
                _pickupLocation!,
              );
            }
          }
        });
  }

  // ---------------- UTILS ----------------
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}
