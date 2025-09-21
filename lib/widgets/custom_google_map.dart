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
  static const String _googleDirectionsApiKey = 'AIzaSyCCOlStSbMeZ6qNoHO9Dz0KODmfpgWcXTQ';
  static const String _googleDirectionsUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  // Streams and Timers
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<DatabaseEvent>? _rideStream;
  StreamSubscription<DatabaseEvent>? _driverLocationStream;
  StreamSubscription<DatabaseEvent>? _rideRequestStream;

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
      zoom: 14,
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
            top: 16,
            right: 16,
            child: FloatingActionButton(
              onPressed: _toggleMode,
              backgroundColor: _isDriverMode ? Colors.green : Colors.blue,
              child: Icon(_isDriverMode ? Icons.drive_eta : Icons.person),
            ),
          ),

          // GPS Location button
          Positioned(
            bottom: 100,
            right: 16,
            child: FloatingActionButton(
              onPressed: _getCurrentLocation,
              backgroundColor: Colors.orange,
              child: const Icon(Icons.my_location),
            ),
          ),

          // Driver-specific buttons
          if (_isDriverMode) ...[
            // Start/Stop tracking button
            Positioned(
              bottom: 180,
              right: 16,
              child: FloatingActionButton(
                onPressed: _toggleTracking,
                backgroundColor: _isTrackingActive ? Colors.red : Colors.green,
                child: Icon(_isTrackingActive ? Icons.stop : Icons.play_arrow),
              ),
            ),
            // Accept ride button (when ride is requested)
            if (_rideStatus == 'requested')
              Positioned(
                bottom: 260,
                right: 16,
                child: FloatingActionButton.extended(
                  onPressed: _acceptRide,
                  backgroundColor: Colors.green,
                  icon: const Icon(Icons.check),
                  label: const Text('Accept Ride'),
                ),
              ),
            // Start ride button (when ride is accepted)
            if (_rideStatus == 'accepted')
              Positioned(
                bottom: 260,
                right: 16,
                child: FloatingActionButton.extended(
                  onPressed: _startRide,
                  backgroundColor: Colors.blue,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start Ride'),
                ),
              ),
            // Complete ride button (when ride is started)
            if (_rideStatus == 'started')
              Positioned(
                bottom: 260,
                right: 16,
                child: FloatingActionButton.extended(
                  onPressed: _completeRide,
                  backgroundColor: Colors.green,
                  icon: const Icon(Icons.check_circle),
                  label: const Text('Complete Ride'),
                ),
              ),
          ],

          // Rider-specific buttons
          if (!_isDriverMode) ...[
            // Set pickup location button
            Positioned(
              bottom: 180,
              right: 16,
              child: FloatingActionButton(
                onPressed: _setPickupLocation,
                backgroundColor: Colors.purple,
                child: const Icon(Icons.location_on),
              ),
            ),
            // Set destination button
            Positioned(
              bottom: 260,
              right: 16,
              child: FloatingActionButton(
                onPressed: _setDestinationLocation,
                backgroundColor: Colors.red,
                child: const Icon(Icons.place),
              ),
            ),
            // Request ride button
            if (_pickupLocation != null &&
                _destinationLocation != null &&
                _rideStatus == 'idle')
              Positioned(
                bottom: 340,
                right: 16,
                child: FloatingActionButton.extended(
                  onPressed: _requestRide,
                  backgroundColor: Colors.blue,
                  icon: const Icon(Icons.local_taxi),
                  label: const Text('Request Ride'),
                ),
              ),
            // Cancel ride button
            if (_rideStatus == 'requested' || _rideStatus == 'accepted')
              Positioned(
                bottom: 340,
                right: 16,
                child: FloatingActionButton.extended(
                  onPressed: _cancelRide,
                  backgroundColor: Colors.red,
                  icon: const Icon(Icons.cancel),
                  label: const Text('Cancel Ride'),
                ),
              ),
          ],

          // Status and ride info
          Positioned(
            bottom: 16,
            left: 16,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _getStatusMessage(),
                    style: const TextStyle(color: Colors.white),
                  ),
                  if (_currentRideId.isNotEmpty)
                    Text(
                      'Ride ID: ${_currentRideId.substring(_currentRideId.length - 6)}',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  if (_estimatedFare > 0)
                    Text(
                      'Estimated Fare: \$${_estimatedFare.toStringAsFixed(2)}',
                      style: const TextStyle(color: Colors.green, fontSize: 12),
                    ),
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
            distanceFilter: 5,
          ),
        ).listen((position) async {
          setState(() {
            _driverLocation = LatLng(position.latitude, position.longitude);
            _userLocation = _driverLocation;
          });

          // Update driver location in Firebase
          await _driversRef.child(_userId).update({
            'location': {
              'lat': _driverLocation!.latitude,
              'lng': _driverLocation!.longitude,
            },
            'lastSeen': ServerValue.timestamp,
          });

          // Update ride location if active
          if (_isRideActive && _currentRideId.isNotEmpty) {
            await _ridesRef.child(_currentRideId).child('driverLocation').set({
              'lat': _driverLocation!.latitude,
              'lng': _driverLocation!.longitude,
              'timestamp': ServerValue.timestamp,
            });
          }

          _updateMarkers();
          _calculateDistance();

          // Get real routes if needed
          if (_isRideActive && _pickupLocation != null) {
            if (_rideStatus == 'accepted') {
              _getRouteDirections(_driverLocation!, _pickupLocation!);
            } else if (_rideStatus == 'started' &&
                _destinationLocation != null) {
              _getRouteDirections(_driverLocation!, _destinationLocation!);
            }
          }
        });
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

            // Get real route between driver and rider
            if (_riderLocation != null && _driverLocation != null) {
              _getRouteDirections(_driverLocation!, _riderLocation!);
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

  void _requestRide() {
    if (_pickupLocation == null || _destinationLocation == null) {
      _showSnackBar('Please set both pickup and destination locations');
      return;
    }

    setState(() {
      _currentRideId = DateTime.now().millisecondsSinceEpoch.toString();
      _rideStatus = 'requested';
    });

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

    _ridesRef.child(_currentRideId).set({
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

    _ridersRef.child(_userId).update({
      'currentRideId': _currentRideId,
      'location': {
        'lat': _riderLocation!.latitude,
        'lng': _riderLocation!.longitude,
      },
    });

    _listenToRideUpdates();
    _showSnackBar('Ride request sent! Looking for drivers...');
  }

  void _cancelRide() {
    if (_currentRideId.isEmpty) return;

    _ridesRef.child(_currentRideId).update({
      'status': 'cancelled',
      'cancelledAt': DateTime.now().millisecondsSinceEpoch,
    });

    _ridersRef.child(_userId).update({'currentRideId': ''});

    setState(() {
      _currentRideId = '';
      _rideStatus = 'idle';
      _estimatedFare = 0.0;
    });

    _showSnackBar('Ride cancelled');
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
          _showSnackBar('Driver accepted your ride!');
          _startRiderMode();

          if (rideData['driverLocation'] != null) {
            final driverLocData = rideData['driverLocation'];
            _driverLocation = LatLng(
              driverLocData['lat'],
              driverLocData['lng'],
            );

            if (_pickupLocation != null) {
              _getRouteDirections(_driverLocation!, _pickupLocation!);
            }
          }
        } else if (newStatus == 'started') {
          _showSnackBar('Driver is on the way!');
        } else if (newStatus == 'completed') {
          _showSnackBar('Ride completed! Thank you for using our service.');
          setState(() {
            _currentRideId = '';
            _rideStatus = 'idle';
          });
        }
      }
    });
  }

  // ---------------- LOCATION METHODS ----------------
  Future<void> _requestLocationPermissions() async {
    try {
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }

      if (permission == LocationPermission.deniedForever) {
        _showSnackBar(
          'Location permissions are permanently denied. Please enable in settings.',
        );
        return;
      }

      if (permission == LocationPermission.denied) {
        _showSnackBar(
          'Location permissions denied. You can still tap the map to set location.',
        );
        return;
      }

      _showSnackBar(
        'Location permissions granted! Tap GPS button or map to set location.',
      );
    } catch (e) {
      print('Permission error: $e');
      _showSnackBar(
        'Location service error. You can still tap the map to set location.',
      );
    }
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

    if (_isDriverMode && _driverLocation != null && _pickupLocation != null) {
      // Driver to pickup route - use real route if available
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

      // Pickup to destination route
      if (_destinationLocation != null) {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('pickup_to_destination'),
            points: [_pickupLocation!, _destinationLocation!],
            color: Colors.blue,
            width: 3,
            patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          ),
        );
      }
    } else if (!_isDriverMode &&
        _riderLocation != null &&
        _driverLocation != null) {
      // Rider to driver route - use real route if available
      if (_routePoints.isNotEmpty) {
        polylines.add(
          Polyline(
            polylineId: const PolylineId('rider_to_driver'),
            points: _routePoints,
            color: Colors.blue,
            width: 3,
          ),
        );
      } else {
        // Fallback to straight line
        polylines.add(
          Polyline(
            polylineId: const PolylineId('rider_to_driver'),
            points: [_riderLocation!, _driverLocation!],
            color: Colors.blue,
            width: 3,
          ),
        );
      }
    }
  }

  void _moveCameraToLocation(LatLng location) {
    googleMapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: location, zoom: 15),
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

  // ---------------- UTILS ----------------
  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}
