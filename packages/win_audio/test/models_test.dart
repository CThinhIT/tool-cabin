import 'package:flutter_test/flutter_test.dart';
import 'package:win_audio/win_audio.dart';

void main() {
  test('parses the device list JSON of wa_list_devices', () {
    // Shape and escaping exactly as produced by devices.cpp (seen on the dev
    // machine, ids shortened).
    const json =
        '[{"id":"{0.0.1.00000000}.{a}","name":"Microphone (DeskIn(R) Virtual Audio Device)","isDefault":true,"isDefaultComm":true},'
        '{"id":"{0.0.0.00000000}.{b}","name":"CABLE Input (VB-Audio Virtual Cable)","isDefault":false,"isDefaultComm":false}]';
    final list = AudioDeviceInfo.listFromJson(json);
    expect(list, hasLength(2));
    expect(list[0].name, 'Microphone (DeskIn(R) Virtual Audio Device)');
    expect(list[0].isDefault, isTrue);
    expect(list[0].isVirtualCable, isFalse);
    expect(list[1].isVirtualCable, isTrue);
    expect(list[1].id, '{0.0.0.00000000}.{b}');
  });

  test('parses the session list JSON of wa_list_sessions', () {
    const json =
        '[{"pid":0,"exe":"(system sounds)","rootPid":0,"system":true,"state":"inactive","volume":1.0000,"muted":false,"deviceId":"d1","deviceName":"Realtek"},'
        '{"pid":17504,"exe":"Discord.exe","rootPid":18588,"system":false,"state":"active","volume":0.2500,"muted":false,"deviceId":"d2","deviceName":"Tai nghe \\"X\\""}]';
    final list = AudioSessionInfo.listFromJson(json);
    expect(list, hasLength(2));
    expect(list[0].isSystem, isTrue);
    final discord = list[1];
    expect(discord.exe, 'Discord.exe');
    expect(discord.pid, 17504);
    expect(discord.rootPid, 18588);
    expect(discord.isActive, isTrue);
    expect(discord.volume, 0.25);
    expect(discord.deviceName, 'Tai nghe "X"');
  });

  test('recognizes device-lost HRESULTs as delivered by the event callback', () {
    // The C side passes the HRESULT sign-extended into an int64.
    expect(
      const WinAudioException('x', hresult: -2004287484).isDeviceLost,
      isTrue,
    ); // 0x88890004
    expect(
      const WinAudioException('x', hresult: -2147023728).isDeviceLost,
      isTrue,
    ); // 0x80070490
    expect(const WinAudioException('x', hresult: -1).isDeviceLost, isFalse);
    expect(const WinAudioException('x').isDeviceLost, isFalse);
  });
}
