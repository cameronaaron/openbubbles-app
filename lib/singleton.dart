import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// import 'package:adhara_socket_io/manager.dart';
// import 'package:adhara_socket_io/options.dart';
// import 'package:adhara_socket_io/socket.dart';
import 'package:flutter_socket_io/socket_io_manager.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
// import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter_socket_io/flutter_socket_io.dart';
import 'package:contacts_service/contacts_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'repository/models/attachment.dart';
import 'repository/models/message.dart';
import 'settings.dart';
import './repository/blocs/chat.dart';
import './repository/models/chat.dart';

class Singleton {
  factory Singleton() {
    return _singleton;
  }

  static final Singleton _singleton = Singleton._internal();

  Singleton._internal();

  Directory appDocDir;

  // Chat repo
  ChatBloc chatContext = new ChatBloc();
  List<Chat> chats = [];

  List<Contact> contacts = <Contact>[];
  //interface with native code
  final platform = const MethodChannel('samples.flutter.dev/fcm');

  List<String> processedGUIDS = [];
  //settings
  Settings settings;

  //for setup, when the user has no saved db
  Completer setupProgress = new Completer();

  SharedPreferences sharedPreferences;
  //Socket io
  // SocketIOManager manager;
  SocketIO socket;

  //setstate for these widgets
  List<Function> subscribers = <Function>[];

  String token;

  Future setup() {
    return setupProgress.future;
  }

  void subscribe(Function cb) {
    _singleton.subscribers.add(cb);
  }

  void notify() {
    debugPrint(
        "notifying subscribers: " + _singleton.subscribers.length.toString());
    for (int i = 0; i < _singleton.subscribers.length; i++) {
      _singleton.subscribers[i]();
    }
  }

  void getSavedSettings() async {
    appDocDir = await getApplicationDocumentsDirectory();
    _singleton.sharedPreferences = await SharedPreferences.getInstance();
    var result = _singleton.sharedPreferences.getString('Settings');
    if (result != null) {
      Map resultMap = jsonDecode(result);
      _singleton.settings = Settings.fromJson(resultMap);
    }
    _singleton.startSocketIO();
    _singleton.authFCM();
  }

  void saveSettings(Settings settings) async {
    if (_singleton.sharedPreferences == null) {
      _singleton.sharedPreferences = await SharedPreferences.getInstance();
    }
    _singleton.sharedPreferences.setString('Settings', jsonEncode(settings));
    await _singleton.authFCM();
    _singleton.startSocketIO();
  }

  void socketStatusUpdate(data) {
    switch (data) {
      case "connect":
        debugPrint("connected");
        authFCM();
        syncChats();
        return;
      case "disconnect":
        debugPrint("disconnected");
        return;
      default:
        return;
    }
    // debugPrint("update status: ${data.toString()}");
  }

  startSocketIO() async {
    // If we have no chats, loads chats from database
    if (_singleton.chats.length == 0) {
      List<Chat> _chats = await Chat.find();
      if (_chats.length != 0) {
        _singleton.chats = _chats;
        setupProgress.complete();
      }
    }

    // If we already have a socket connection, kill it
    if (_singleton.socket != null) {
      _singleton.socket.destroy();
    }

    debugPrint("Starting socket io with the server: ${_singleton.settings.serverAddress}");

    try {
      // Create a new socket connection
      _singleton.socket = SocketIOManager().createSocketIO(
          _singleton.settings.serverAddress, "/",
          query: "guid=${_singleton.settings.guidAuthKey}",
          socketStatusCallback: socketStatusUpdate);
      _singleton.socket.init();
      _singleton.socket.connect();

      // Let us know when our device was added
      _singleton.socket.subscribe("fcm-device-id-added", (data) {
        debugPrint("fcm device added: " + data.toString());
      });

      // Let us know when there is an error
      _singleton.socket.subscribe("error", (data) {
        debugPrint("An error occurred: " + data.toString());
      });
    } catch (e) {
      debugPrint("FAILED TO CONNECT");
    }
  }

  void syncChats() async {
    debugPrint("Syncing chats from the server");
    _singleton.socket.sendMessage("get-chats", '{}', (data) async {
      List chats = jsonDecode(data)["data"];

      debugPrint("Got ${chats.length} chats from server. Adding to database...");
      for (int i = 0; i < chats.length; i++) {
        // Get the chat and add it to the DB
        debugPrint(chats[i].toString());
        Chat chat = Chat.fromMap(chats[i]);

        // This will check for an existing chat as well
        debugPrint("Saving/Updating Chat: ${chat.chatIdentifier}");
        await chat.save();

        debugPrint("Syncing messages from the server");
        Map<String, dynamic> params = Map();
        params["identifier"] = chat.guid;
        params["limit"] = 100;
        _singleton.socket.sendMessage("get-chat-messages", jsonEncode(params), (data) async {
          List messages = jsonDecode(data)["data"];
          debugPrint("Got ${messages.length} messages for chat, ${chat.chatIdentifier}");

          messages.forEach((item) async {
            Message message = Message.fromMap(item);
            await chat.addMessage(message);

            // Create the attachments
            List<dynamic> attachments = item['attachments'];
            if (attachments.length > 0) {
              debugPrint("Saving ${attachments.length} attachments");
            }
  
            attachments.forEach((attachmentItem) async {
              Attachment file = Attachment.fromMap(attachmentItem);
              await file.save();
            });
          });
        });


        // Map<String, dynamic> params = Map();
        // params["identifier"] = chat.guid;
        // params["limit"] = 200;
        // _singleton.socket.sendMessage("get-chat-messages", jsonEncode(params),
        //     (data) {
        //   List messagesData = jsonDecode(data)["data"];
        //   List<Message> messages = <Message>[];
        //   for (int j = 0; j < messagesData.length; j++) {
        //     Message message = Message(messagesData[j]);
        //     messages.add(message);
        //   }
        //   RepositoryServiceMessage.addMessagesToChat(messages)
        //       .whenComplete(() {
        //     if (i == chats.length - 1) {
        //       debugPrint("finished setting up");
        //       notify();
        //       setupProgress.complete();
        //     }
        //   });
        // });
      }
    });
  }

  void closeSocket() {
    _singleton.socket.destroy();
    _singleton.socket = null;
  }

  Future<void> authFCM() async {
    try {
      final String result =
          await platform.invokeMethod('auth', _singleton.settings.fcmAuthData);
      token = result;
      if (_singleton.socket != null)
        _singleton.socket.sendMessage("add-fcm-device-id",
            jsonEncode({"deviceId": token, "deviceName": "android-client"}));
      debugPrint(token);
    } on PlatformException catch (e) {
      token = "Failed to get token: " + e.toString();
      debugPrint(token);
    }
  }

  // void handleNewMessage(Map<String, dynamic> data) {
  //   Message message = new Message(data);
  //   if (message.isFromMe) {
  //     RepositoryServiceMessage.attemptToFixMessage(message);
  //   } else {
  //     RepositoryServiceMessage.addMessagesToChat([message]);
  //   }
  //   _singleton.processedGUIDS.add(message.guid);
  //   // if (_singleton.socket != null) {
  //   //   syncMessages();
  //   // } else {
  //   //   debugPrint("not syncing, socket is null");
  //   // }
  //   sortChats();
  // }

  // void sortChats() async {
  //   Map<String, Message> guidToMessage = new Map<String, Message>();
  //   int counter = 0;
  //   for (int i = 0; i < _singleton.chats.length; i++) {
  //     RepositoryServiceMessage.getMessagesFromChat(_singleton.chats[i].guid)
  //         .then((List<Message> messages) {
  //       counter++;
  //       if (messages.length > 0) {
  //         RepositoryServiceChats.updateChatTime(
  //                 _singleton.chats[i].guid, messages.first.dateCreated)
  //             .then((int n) {
  //           if (counter == _singleton.chats.length - 1) {
  //             RepositoryServiceChats.getAllChats().then((List<Chat> chats) {
  //               _singleton.chats = chats;
  //               notify();
  //             });
  //           }
  //         });
  //       } else {
  //         if (counter == _singleton.chats.length - 1) {
  //           RepositoryServiceChats.getAllChats().then((List<Chat> chats) {
  //             _singleton.chats = chats;
  //             notify();
  //           });
  //         }
  //       }
  //     });
  //   }

    // updatedChats.sort(
    //     (a, b) => a.lastMessageTimeStamp.compareTo(b.lastMessageTimeStamp));
    // _singleton.chats = updatedChats;
    // notify();
    // }

  // void sendMessage(Message message) {
  //   RepositoryServiceMessage.addEmptyMessageToChat(message).whenComplete(() {
  //     notify();
  //   });
  //   Map params = Map();
  //   params["guid"] = message.chatGuid;
  //   params["message"] = message.text;
  //   _singleton.socket.sendMessage("send-message", jsonEncode(params));
  // }

  // void syncMessages() {
  //   debugPrint("sync messages");
  //   for (int i = 0; i < _singleton.chats.length; i++) {
  //     Map<String, dynamic> params = new Map();
  //     params["identifier"] = _singleton.chats[i].guid;
  //     params["limit"] = 100;
  //     _singleton.socket.sendMessage("get-chat-messages", jsonEncode(params),
  //         (_messages) {
  //       List dataMessages = _messages["data"];
  //       List<Message> messages = <Message>[];
  //       for (int i = 0; i < dataMessages.length; i++) {
  //         messages.add(new Message(dataMessages[i]));
  //       }
  //       RepositoryServiceMessage.addMessagesToChat(messages)
  //           .then((void newMessages) {
  //         notify();
  //       });
  //     });
  //   }
  // }

  // Future getImage(Map attachment, String messageGuid) {
  //   Completer completer = new Completer();
  //   Map<String, dynamic> params = new Map();
  //   String guid = attachment["guid"];
  //   params["identifier"] = guid;
  //   debugPrint("getting attachment");
  //   _singleton.socket.sendMessage("get-attachment", jsonEncode(params),
  //       (String data) async {
  //     // Read the data as an object
  //     dynamic attachmentResponse = jsonDecode(data);
  //     String fileName = attachmentResponse["data"]["transferName"];
  //     String appDocPath = _singleton.appDocDir.path;
  //     String pathName = "$appDocPath/$guid/$fileName";

  //     // Pull out the bytes and map them to a Uint8List
  //     Map<String, dynamic> newData = attachmentResponse["data"]["data"];
  //     List<int> intList = newData.values.map((s) => s as int).toList();

  //     // Create the Uint8List and write the file
  //     Uint8List bytes = Uint8List.fromList(intList);
  //     File file = await writeToFile(bytes, pathName);
  //     completer.complete(file);
  //   });

  //   return completer.future;
  // }

  // Future<File> writeToFile(Uint8List data, String path) async {
  //   // final buffer = data.buffer;
  //   File file = await new File(path).create(recursive: true);
  //   return file.writeAsBytes(data);
  // }
}