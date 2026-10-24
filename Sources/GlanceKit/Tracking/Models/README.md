# Mesh tracker models

Source: Google MediaPipe Face Landmarker (Apache-2.0), official URL
https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task
(sha256 64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff). Bundle members used:

| file in bundle | sha256 |
|---|---|
| face_detector.tflite | b4578f35940bf5a1a655214a1cce5cab13eba73c1297cd78e1a04c2380b0152f |
| face_landmarks_detector.tflite | c7d54204ce0448474c7f3fa9af494787c0965cbdd6f20fc72867e43046bd43d5 |

Converted with tf2onnx 1.16.1 (`python -m tf2onnx.convert --tflite X.tflite --output X.onnx --opset 13`,
tensorflow 2.16.2, onnx 1.16.2). Validated with onnxruntime 1.19.2. The .onnx files here:
    b49a1f2ef3440709d56bbd3bf091dc427aa772883e996e9a80310f620c7ddf4e  face_detector.onnx
    3c913d96aa89a86851341d83942a192b72f6f086bf626c3ac38a44a6f4ccaf35  face_landmarks_detector.onnx
