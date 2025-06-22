import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:typed_data';

void main() {
  runApp(const MaterialApp(home: DeviceDiscoveryPage()));
}

class DeviceDiscoveryPage extends StatefulWidget {
  const DeviceDiscoveryPage({super.key});
  @override
  State<DeviceDiscoveryPage> createState() => DeviceDiscoveryPageState();
}

class DeviceDiscoveryPageState extends State<DeviceDiscoveryPage> {
  List<Map<String, String>> devices = [];
  bool scanning = false;
  String status = "Idle";

  Future<void> scanDevices() async {
    setState(() {
      scanning = true;
      status = "Scanning...";
      devices.clear();
    });

    for (int i = 1; i < 255; i++) {
      String ip = '192.168.43.$i';
      try {
        final socket = await Socket.connect(ip, 5000, timeout: const Duration(milliseconds: 150));
        String name = await socket.map((data) => String.fromCharCodes(data)).firstWhere((line) => line.isNotEmpty).timeout(const Duration(seconds: 1), onTimeout: () => 'Unknown');
        devices.add({'ip': ip, 'name': name.trim()});
        socket.destroy();
      } catch (_) {}
    }

    setState(() {
      scanning = false;
      status = devices.isEmpty ? "No devices found" : "Scan complete";
    });
  }

  @override
  void initState() {
    super.initState();
    scanDevices();
  }

  void connectTo(String ip) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => RemoteControlPage(ip: ip),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.cyan[900],
        title: const Text("Available Devices", style: TextStyle(color: Colors.white)),
      ),
      body: Column(
        children: [
          if (scanning) const LinearProgressIndicator(),
          Text(status, style: const TextStyle(color: Colors.cyanAccent)),
          Expanded(
            child: ListView.builder(
              itemCount: devices.length,
              itemBuilder: (_, index) {
                return ListTile(
                  title: Text(devices[index]['name'] ?? 'Unknown', style: const TextStyle(color: Colors.white)),
                  subtitle: Text(devices[index]['ip']!, style: const TextStyle(color: Colors.cyanAccent)),
                  onTap: () => connectTo(devices[index]['ip']!),
                );
              },
            ),
          ),
          ElevatedButton(
            onPressed: scanDevices,
            child: const Text("Rescan"),
          ),
        ],
      ),
    );
  }
}

class RemoteControlPage extends StatefulWidget {
  final String ip;
  const RemoteControlPage({super.key, required this.ip});
  @override
  State<RemoteControlPage> createState() => RemoteControlPageState();
}

class RemoteControlPageState extends State<RemoteControlPage> {
  late Socket socket;
  bool ctrl = false, shift = false, win = false;
  double? startScrollY;

  bool downloading = false;
  double downloadProgress = 0.0;
  bool minimizedDownloadUI = false;
  String downloadFilename = "";

  bool receivingFile = false;
  IOSink? fileSink;
  int fileSize = 0;
  int bytesReceived = 0;

  @override
  void initState() {
    super.initState();
    connect();
  }

  Future<void> connect() async {
    socket = await Socket.connect(widget.ip, 5000);
    socket.listen(processIncomingData);
  }

  void send(String message) {
    socket.write('$message\n');
  }

  Future<void> sendFile() async {
    final result = await FilePicker.platform.pickFiles();
    if (result != null) {
      final file = File(result.files.single.path!);
      final name = result.files.single.name;
      final bytes = await file.readAsBytes();
      final header = jsonEncode({"filename": name, "size": bytes.length});
      socket.write("file:$header\n");
      await Future.delayed(const Duration(milliseconds: 300));
      socket.add(bytes);
      send("file_done");
    }
  }

  Future<void> processIncomingData(Uint8List data) async {
    if (receivingFile) {
      fileSink?.add(data);
      bytesReceived += data.length;
      setState(() {
        downloadProgress = bytesReceived / fileSize;
      });

      if (bytesReceived >= fileSize) {
        await fileSink?.close();
        setState(() {
          downloading = false;
          downloadProgress = 0;
          downloadFilename = "";
          receivingFile = false;
          fileSink = null;
        });
      }
      return;
    }

    final message = utf8.decode(data);
    if (message.startsWith("file:")) {
      final headerJson = message.substring(5).trim();
      final info = jsonDecode(headerJson);
      downloadFilename = info['filename'];
      fileSize = info['size'];

      bool accept = await showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text("Incoming File"),
          content: Text("Do you want to receive \"$downloadFilename\" (${(fileSize / 1024).toStringAsFixed(1)} KB)?"),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Reject")),
            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text("Accept")),
          ],
        ),
      );

      if (accept) {
        final dir = await getApplicationDocumentsDirectory();
        final file = File("${dir.path}/$downloadFilename");
        fileSink = file.openWrite();
        setState(() {
          downloading = true;
          downloadProgress = 0;
          minimizedDownloadUI = false;
          bytesReceived = 0;
          receivingFile = true;
        });
      } else {
        send("file_rejected");
      }
    }
  }

  @override
  void dispose() {
    socket.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: Colors.cyan[900],
            title: Text("Connected to ${widget.ip}", style: const TextStyle(color: Colors.white)),
            actions: [
              IconButton(
                icon: const Icon(Icons.attach_file, color: Colors.white),
                onPressed: sendFile,
              )
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: GestureDetector(
                  onPanUpdate: (details) {
                    final dx = (details.delta.dx * 2).toInt();
                    final dy = (details.delta.dy * 2).toInt();
                    send("move:$dx,$dy");
                  },
                  onTap: () => send("left_click"),
                  onLongPress: () => send("right_click"),
                  onScaleStart: (details) {
                    startScrollY = details.focalPoint.dy;
                  },
                  onScaleUpdate: (details) {
                    if (startScrollY != null) {
                      double deltaY = details.focalPoint.dy - startScrollY!;
                      if (deltaY.abs() > 10) {
                        send("scroll:${deltaY > 0 ? 'down' : 'up'}");
                        startScrollY = details.focalPoint.dy;
                      }
                    }
                  },
                  child: Container(
                    color: Colors.cyan[800],
                    child: const Center(
                      child: Text("Touchpad", style: TextStyle(color: Colors.white, fontSize: 18)),
                    ),
                  ),
                ),
              ),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                children: [
                  ElevatedButton(onPressed: () => send("left_click"), child: const Text("Left")),
                  ElevatedButton(onPressed: () => send("right_click"), child: const Text("Right")),
                  ElevatedButton(onPressed: () => send("key:up"), child: const Text("\u2191")),
                  ElevatedButton(onPressed: () => send("key:down"), child: const Text("\u2193")),
                  ElevatedButton(onPressed: () => send("key:left"), child: const Text("\u2190")),
                  ElevatedButton(onPressed: () => send("key:right"), child: const Text("\u2192")),
                  ElevatedButton(onPressed: () => send("media:play_pause"), child: const Icon(Icons.play_arrow)),
                  ElevatedButton(onPressed: () => send("media:next"), child: const Icon(Icons.skip_next)),
                  ElevatedButton(onPressed: () => send("media:prev"), child: const Icon(Icons.skip_previous)),
                  ElevatedButton(
                    onPressed: () {
                      setState(() => ctrl = !ctrl);
                      send(ctrl ? "down:ctrl" : "up:ctrl");
                    },
                    child: Text("Ctrl", style: TextStyle(color: ctrl ? Colors.green : Colors.white)),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      setState(() => shift = !shift);
                      send(shift ? "down:shift" : "up:shift");
                    },
                    child: Text("Shift", style: TextStyle(color: shift ? Colors.green : Colors.white)),
                  ),
                  ElevatedButton(
                    onPressed: () {
                      setState(() => win = !win);
                      send(win ? "down:win" : "up:win");
                    },
                    child: Text("Win", style: TextStyle(color: win ? Colors.green : Colors.white)),
                  ),
                  ElevatedButton(onPressed: () => send("key:enter"), child: const Text("Enter")),
                  ElevatedButton(onPressed: () => send("key:backspace"), child: const Text("Backspace")),
                  ElevatedButton(
                    onPressed: () async {
                      String? input = await showDialog(
                        context: context,
                        builder: (BuildContext context) => AlertDialog(
                          backgroundColor: Colors.cyan[900],
                          title: const Text("Keyboard Input", style: TextStyle(color: Colors.white)),
                          content: TextField(
                            style: const TextStyle(color: Colors.white),
                            decoration: const InputDecoration(labelText: "Enter text", labelStyle: TextStyle(color: Colors.cyanAccent)),
                            onSubmitted: (value) => Navigator.of(context).pop(value),
                          ),
                        ),
                      );
                      if (input != null) send("text:$input");
                    },
                    child: const Icon(Icons.keyboard, color: Colors.white),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (downloading)
          minimizedDownloadUI
              ? Positioned(
                  top: 20,
                  right: 20,
                  child: GestureDetector(
                    onTap: () {
                      setState(() {
                        minimizedDownloadUI = false;
                      });
                    },
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        CircularProgressIndicator(
                          value: downloadProgress,
                          backgroundColor: Colors.white24,
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                        ),
                        Text(
                          "${(downloadProgress * 100).toInt()}%",
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                )
              : Center(
                  child: Container(
                    color: Colors.black.withOpacity(0.85),
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              "Downloading $downloadFilename",
                              style: const TextStyle(color: Colors.white, fontSize: 16),
                            ),
                            IconButton(
                              onPressed: () {
                                setState(() => minimizedDownloadUI = true);
                              },
                              icon: const Icon(Icons.close, color: Colors.white),
                            )
                          ],
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: 250,
                          child: LinearProgressIndicator(
                            value: downloadProgress,
                            backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.cyanAccent),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          "${(downloadProgress * 100).toInt()}%",
                          style: const TextStyle(color: Colors.cyanAccent),
                        )
                      ],
                    ),
                  ),
                ),
      ],
    );
  }
}