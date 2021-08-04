import 'dart:async';

import 'package:bluebubbles/blocs/chat_bloc.dart';
import 'package:bluebubbles/helpers/message_helper.dart';
import 'package:bluebubbles/helpers/utils.dart';
import 'package:bluebubbles/managers/contact_manager.dart';
import 'package:bluebubbles/managers/settings_manager.dart';
import 'package:bluebubbles/repository/models/chat.dart';
import 'package:bluebubbles/repository/models/fcm_data.dart';
import 'package:bluebubbles/repository/models/settings.dart';
import 'package:bluebubbles/socket_manager.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

enum SetupOutputType { ERROR, LOG }

class SetupData {
  double progress;
  List<SetupOutputData> output = [];

  SetupData(this.progress, this.output);
}

class SetupOutputData {
  String text;
  SetupOutputType type;

  SetupOutputData(this.text, this.type);
}

class SetupBloc {
  final Rxn<SetupData> data = Rxn<SetupData>();
  final Rxn<SocketState> connectionStatus = Rxn<SocketState>();
  StreamSubscription? connectionSubscription;

  double _progress = 0.0;
  int _currentIndex = 0;
  List chats = [];
  final RxBool isSyncing = false.obs;
  double numberOfMessagesPerPage = 25;
  bool downloadAttachments = false;
  bool skipEmptyChats = true;

  double get progress => _progress;
  int? processId;

  List<SetupOutputData> output = [];

  SetupBloc();

  Future<void> connectToServer(FCMData data, String serverURL, String password) async {
    Settings settingsCopy = SettingsManager().settings;
    if (SocketManager().state == SocketState.CONNECTED && settingsCopy.serverAddress.value == serverURL) {
      debugPrint("Not reconnecting to server we are already connected to!");
      return;
    }

    settingsCopy.serverAddress.value = getServerAddress(address: serverURL) ?? settingsCopy.serverAddress.value;
    settingsCopy.guidAuthKey.value = password;

    await SettingsManager().saveSettings(settingsCopy);
    await SettingsManager().saveFCMData(data);
    await SocketManager().authFCM(catchException: false, force: true);
    await SocketManager().startSocketIO(forceNewConnection: true, catchException: false);
    connectionSubscription = SocketManager().connectionStateStream.listen((event) {
      connectionStatus.value = event;

      if (isSyncing.value) {
        switch (event) {
          case SocketState.DISCONNECTED:
            addOutput("Disconnected from socket!", SetupOutputType.ERROR);
            break;
          case SocketState.CONNECTED:
            addOutput("Connected to socket!", SetupOutputType.LOG);
            break;
          case SocketState.ERROR:
            addOutput("Socket connection error!", SetupOutputType.ERROR);
            break;
          case SocketState.CONNECTING:
            addOutput("Reconnecting to socket...", SetupOutputType.LOG);
            break;
          case SocketState.FAILED:
            addOutput("Connection failed, cancelling download.", SetupOutputType.ERROR);
            closeSync();
            break;
          default:
            break;
        }
      }
    });
  }

  void handleError(String error) {
    addOutput(error, SetupOutputType.ERROR);
    data.value = SetupData(-1, output);
    closeSync();
  }

  Future<void> startFullSync(Settings settings) async {
    // Make sure we aren't already syncing
    if (isSyncing.value) return;

    // Setup syncing process
    processId = SocketManager().addSocketProcess(([bool finishWithError = false]) {});
    isSyncing.value = true;

    // Set the last sync date (for incremental, even though this isn't incremental)
    // We won't try an incremental sync until the last (full) sync date is set
    Settings _settingsCopy = SettingsManager().settings;
    _settingsCopy.lastIncrementalSync.value = DateTime.now().millisecondsSinceEpoch;
    await SettingsManager().saveSettings(_settingsCopy);

    // Some safetly logging
    Timer timer = Timer(Duration(seconds: 15), () {
      if (_progress == 0) {
        addOutput("This is taking a while! Please Ensure that System Disk Access is granted on the mac!",
            SetupOutputType.ERROR);
      }
    });

    try {
      addOutput("Getting Chats...", SetupOutputType.LOG);
      List<Chat> chats = await SocketManager().getChats({});

      // If we got chats, cancel the timer
      timer.cancel();

      if (chats.isEmpty) {
        addOutput("Received no chats, finishing up...", SetupOutputType.LOG);
        finishSetup();
        return;
      }

      addOutput("Received initial chat list. Size: ${chats.length}", SetupOutputType.LOG);
      for (Chat chat in chats) {
        if (chat.guid == "ERROR") {
          addOutput("Failed to save chat data, '${chat.displayName}'", SetupOutputType.ERROR);
        } else {
          try {
            if (!(chat.chatIdentifier ?? "").startsWith("urn:biz")) {
              await chat.save();

              // Re-match the handles with the contacts
              await ContactManager().matchHandles();

              await syncChat(chat);
              addOutput("Finished syncing chat, '${chat.chatIdentifier}'", SetupOutputType.LOG);
            } else {
              addOutput("Skipping syncing chat, '${chat.chatIdentifier}'", SetupOutputType.LOG);
            }
          } catch (ex, stacktrace) {
            addOutput("Failed to sync chat, '${chat.chatIdentifier}'", SetupOutputType.ERROR);
            addOutput(stacktrace.toString(), SetupOutputType.ERROR);
          }
        }

        // If we have no chats, we can't divide by 0
        // Also means there are not chats to sync
        // It should never be 0... but still want to check to be safe.
        if (chats.length == 0) {
          break;
        } else {
          // Set the new progress
          _currentIndex += 1;
          _progress = (_currentIndex / chats.length) * 100;
        }
      }

      // If everything passes, finish the setup
      _progress = 100;
    } catch (ex) {
      addOutput("Failed to sync chats!", SetupOutputType.ERROR);
      addOutput("Error: ${ex.toString()}", SetupOutputType.ERROR);
    } finally {
      finishSetup();
    }

    // Start an incremental sync to catch any messages we missed during setup
    this.startIncrementalSync(settings);
  }

  Future<void> syncChat(Chat chat) async {
    Map<String, dynamic> params = Map();
    params["identifier"] = chat.guid;
    params["withBlurhash"] = false;
    params["limit"] = numberOfMessagesPerPage.round();
    params["where"] = [
      {"statement": "message.service = 'iMessage'", "args": null}
    ];

    List<dynamic> messages = await SocketManager().getChatMessages(params)!;
    addOutput("Received ${messages.length} messages for chat, '${chat.chatIdentifier}'!", SetupOutputType.LOG);

    // Since we got the messages in desc order, we want to reverse it.
    // Reversing it will add older messages before newer one. This should help fix
    // issues with associated message GUIDs
    if (!skipEmptyChats || (skipEmptyChats && messages.length > 0)) {
      await MessageHelper.bulkAddMessages(chat, messages.reversed.toList(),
          notifyForNewMessage: false, checkForLatestMessageText: true);

      // If we want to download the attachments, do it, and wait for them to finish before continuing
      // Commented out because I think this negatively effects sync performance and causes disconnects
      // todo
      // if (downloadAttachments) {
      //   await MessageHelper.bulkDownloadAttachments(chat, messages.reversed.toList());
      // }
    }
  }

  void finishSetup() async {
    addOutput("Finished Setup! Cleaning up...", SetupOutputType.LOG);
    Settings _settingsCopy = SettingsManager().settings;
    _settingsCopy.finishedSetup.value = true;
    await SettingsManager().saveSettings(_settingsCopy);

    ContactManager().contacts = [];
    await ContactManager().getContacts(force: true);
    await ChatBloc().refreshChats(force: true);

    closeSync();
  }

  void addOutput(String _output, SetupOutputType type) {
    debugPrint('[Setup] -> $_output');
    output.add(SetupOutputData(_output, type));
    data.value = SetupData(_progress, output);
  }

  Future<void> startIncrementalSync(Settings settings,
      {String? chatGuid, bool saveDate = true, Function? onConnectionError, Function? onComplete}) async {
    // If we are already syncing, don't sync again
    // Or, if we haven't finished setup, or we aren't connected, don't sync
    if (isSyncing.value || !settings.finishedSetup.value || SocketManager().state != SocketState.CONNECTED) return;

    // Reset the progress
    _progress = 0;

    // Setup the socket process and error handler
    processId = SocketManager().addSocketProcess(([bool finishWithError = false]) {});

    // if (onConnectionError != null) this.onConnectionError = onConnectionError;
    print("UPDATING");
    isSyncing.value = true;
    print(isSyncing.value);
    _progress = 1;

    // Store the time we started syncing
    addOutput("Starting incremental sync for messages since: ${settings.lastIncrementalSync}", SetupOutputType.LOG);
    int syncStart = DateTime.now().millisecondsSinceEpoch;
    await Future.delayed(Duration(seconds: 3));

    // Build request params. We want all details on the messages
    Map<String, dynamic> params = Map();
    if (chatGuid != null) {
      params["chatGuid"] = chatGuid;
    }

    params["withBlurhash"] = false; // Maybe we want it?
    params["limit"] = 1000; // This is arbitrary, hopefully there aren't more messages
    params["after"] = settings.lastIncrementalSync.value; // Get everything since the last sync
    params["withChats"] = true; // We want the chats too so we can save them correctly
    params["withAttachments"] = true; // We want the attachment data
    params["withHandle"] = true; // We want to know who sent it
    params["sort"] = "DESC"; // Sort my DESC so we receive the newest messages first
    params["where"] = [
      {"statement": "message.service = 'iMessage'", "args": null}
    ];

    List<dynamic> messages = await SocketManager().getMessages(params)!;
    if (messages.isEmpty) {
      addOutput("No new messages found during incremental sync", SetupOutputType.LOG);
    } else {
      addOutput("Incremental sync found ${messages.length} messages. Syncing...", SetupOutputType.LOG);
    }

    if (messages.length > 0) {
      await MessageHelper.bulkAddMessages(null, messages, onProgress: (progress, total) {
        _progress = (progress / total) * 100;
        data.value = SetupData(_progress, output);
      });

      // If we want to download the attachments, do it, and wait for them to finish before continuing
      if (downloadAttachments) {
        await MessageHelper.bulkDownloadAttachments(null, messages.reversed.toList());
      }
    }

    _progress = 100;
    addOutput("Finished incremental sync", SetupOutputType.LOG);

    // Once we have added everything, save the last sync date
    if (saveDate) {
      addOutput("Saving last sync date: $syncStart", SetupOutputType.LOG);

      Settings _settingsCopy = SettingsManager().settings;
      _settingsCopy.lastIncrementalSync.value = syncStart;
      SettingsManager().saveSettings(_settingsCopy);
    }

    if (SettingsManager().settings.showIncrementalSync.value)
      // Show a nice lil toast/snackbar
      showSnackbar('Success', '🔄 Incremental sync complete 🔄');

    if (onComplete != null) {
      onComplete();
    }

    // End the sync
    closeSync();
  }

  void closeSync() {
    isSyncing.value = false;
    if (processId != null) SocketManager().finishSocketProcess(processId);
    data.value = null;
    connectionStatus.value = null;

    _progress = 0.0;
    _currentIndex = 0;
    chats = [];
    isSyncing.value = false;
    numberOfMessagesPerPage = 25;
    downloadAttachments = false;
    skipEmptyChats = true;
    processId = null;

    output = [];
    connectionSubscription?.cancel();
  }
}
