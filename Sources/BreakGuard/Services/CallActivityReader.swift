struct CallActivity: Equatable {
    var cameraInUse = false
    var microphoneInUse = false

    var isActive: Bool { cameraInUse || microphoneInUse }

    func selected(for settings: AppSettings) -> Self {
        Self(cameraInUse: cameraInUse && settings.holdBreaksWhileOnCamera,
             microphoneInUse: microphoneInUse && settings.holdBreaksWhileMicrophoneInUse)
    }
}

protocol CallActivityClient {
    func read(includeMicrophone: Bool) -> CallActivity
}

struct SystemCallActivityClient: CallActivityClient {
    var camera = CameraUsageReader()
    var microphone = MicrophoneUsageReader()

    func read(includeMicrophone: Bool) -> CallActivity {
        CallActivity(cameraInUse: camera.isInUse(),
                     microphoneInUse: includeMicrophone && microphone.isInUse())
    }
}
