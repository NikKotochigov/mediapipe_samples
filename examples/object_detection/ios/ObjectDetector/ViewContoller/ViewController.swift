// Copyright 2023 The MediaPipe Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import UIKit
import MediaPipeTasksVision
import UniformTypeIdentifiers
import AVKit

class ViewController: UIViewController {

  // MARK: Storyboards Connections
  @IBOutlet weak var previewView: PreviewView!
  @IBOutlet weak var overlayView: OverlayView!
  @IBOutlet weak var addImageButton: UIButton!
  @IBOutlet weak var cameraUnavailableLabel: UILabel!
  @IBOutlet weak var imageEmptyLabel: UILabel!
  @IBOutlet weak var resumeButton: UIButton!
  @IBOutlet weak var runningModeTabbar: UITabBar!
  @IBOutlet weak var cameraTabbarItem: UITabBarItem!
  @IBOutlet weak var photoTabbarItem: UITabBarItem!
  @IBOutlet weak var bottomSheetViewBottomSpace: NSLayoutConstraint!
  @IBOutlet weak var bottomViewHeightConstraint: NSLayoutConstraint!

  // MARK: Constants
  private let inferenceIntervalMs: Double = 100
  private let inferenceBottomHeight = 220.0
  private let expandButtonHeight = 41.0
  private let edgeOffset: CGFloat = 2.0
  private let labelOffset: CGFloat = 10.0
  private let displayFont = UIFont.systemFont(ofSize: 14.0, weight: .medium)
  private let labelColors = [
    UIColor.red,
    UIColor(displayP3Red: 90.0/255.0, green: 200.0/255.0, blue: 250.0/255.0, alpha: 1.0),
    UIColor.green,
    UIColor.orange,
    UIColor.blue,
    UIColor.purple,
    UIColor.magenta,
    UIColor.yellow,
    UIColor.cyan,
    UIColor.brown
  ]
  private let playerViewController = AVPlayerViewController()
  private var generator:AVAssetImageGenerator?

  // MARK: Instance Variables
  private var videoDetectTimer: Timer?
  private var previousInferenceTimeMs = Date.distantPast.timeIntervalSince1970 * 1000
  private var maxResults = DefaultConstants.maxResults
  private var scoreThreshold = DefaultConstants.scoreThreshold
  private var model = DefaultConstants.model
  private var runningMode: RunningMode = .liveStream {
    didSet {
      objectDetectorHelper = ObjectDetectorHelper(
        model: model,
        maxResults: maxResults,
        scoreThreshold: scoreThreshold,
        runningMode: runningMode,
        delegate: self
      )
    }
  }

  let backgroundQueue = DispatchQueue(
      label: "com.google.mediapipe.ObjectDetection",
      qos: .userInteractive
    )

  // MARK: Controllers that manage functionality
  // Handles all the camera related functionality
  private lazy var cameraCapture = CameraFeedManager(previewView: previewView)

  // Handles all data preprocessing and makes calls to run inference through the
  // `ObjectDetectorHelper`.
  private var objectDetectorHelper: ObjectDetectorHelper?

  // Handles the presenting of results on the screen
  private var inferenceViewController: InferenceViewController?

  // MARK: View Handling Methods
  override func viewDidLoad() {
    super.viewDidLoad()
    // Create object detector helper
    objectDetectorHelper = ObjectDetectorHelper(model: model, maxResults: maxResults, scoreThreshold: scoreThreshold, runningMode: runningMode, delegate: self)

    runningModeTabbar.selectedItem = cameraTabbarItem
    runningModeTabbar.delegate = self
    cameraCapture.delegate = self
    overlayView.clearsContextBeforeDrawing = true
  }
  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
#if !targetEnvironment(simulator)
    if runningMode == .liveStream {
      cameraCapture.checkCameraConfigurationAndStartSession()
    }
#endif
  }

#if !targetEnvironment(simulator)
  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    cameraCapture.stopSession()
  }
#endif

  override var preferredStatusBarStyle: UIStatusBarStyle {
    return .lightContent
  }

  // MARK: Storyboard Segue Handlers
  override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
    super.prepare(for: segue, sender: sender)
    if segue.identifier == "EMBED" {
      inferenceViewController = segue.destination as? InferenceViewController
      inferenceViewController?.maxResults = maxResults
      inferenceViewController?.modelChose = model
      inferenceViewController?.delegate = self
      bottomViewHeightConstraint.constant = inferenceBottomHeight
      bottomSheetViewBottomSpace.constant = -inferenceBottomHeight + expandButtonHeight
      view.layoutSubviews()
    }
  }

  // MARK: IBAction

  @IBAction func addPhotoButtonTouchUpInside(_ sender: Any) {
    openImagePickerController()
  }
  // Resume camera session when click button resume
  @IBAction func resumeButtonTouchUpInside(_ sender: Any) {
    cameraCapture.resumeInterruptedSession { isSessionRunning in
      if isSessionRunning {
        self.resumeButton.isHidden = true
        self.cameraUnavailableLabel.isHidden = true
      }
    }
  }
  // MARK: Private function
  private func openImagePickerController() {
    if UIImagePickerController.isSourceTypeAvailable(.savedPhotosAlbum) {
      let imagePicker = UIImagePickerController()
      imagePicker.delegate = self
      imagePicker.sourceType = .savedPhotosAlbum
      imagePicker.mediaTypes = [UTType.image.identifier, UTType.movie.identifier]
      imagePicker.allowsEditing = false
      DispatchQueue.main.async {
        self.present(imagePicker, animated: true, completion: nil)
      }
    }
  }

  private func removePlayerViewController() {
    playerViewController.view.removeFromSuperview()
    playerViewController.removeFromParent()
  }

  private func processVideo(url: URL) {
    backgroundQueue.async { [weak self] in
      guard let weakSelf = self else { return }
      let objectDetectorHelper = ObjectDetectorHelper(model: weakSelf.model,
                                                      maxResults: weakSelf.maxResults,
                                                      scoreThreshold: weakSelf.scoreThreshold,
                                                      runningMode: .video,
                                                      delegate: nil)
      Task {
        let result = await objectDetectorHelper.detectVideoFile(url: url, inferenceIntervalMs: weakSelf.inferenceIntervalMs)
        DispatchQueue.main.async {
          weakSelf.inferenceViewController?.result = result
          weakSelf.inferenceViewController?.updateData()
          let player = AVPlayer(url: url)
          weakSelf.playerViewController.player = player
          weakSelf.playerViewController.videoGravity = .resizeAspectFill
          weakSelf.playerViewController.showsPlaybackControls = false
          weakSelf.playerViewController.view.frame = weakSelf.previewView.bounds
          weakSelf.previewView.addSubview(weakSelf.playerViewController.view)
          weakSelf.addChild(weakSelf.playerViewController)
          player.play()
          NotificationCenter.default.removeObserver(weakSelf)
          NotificationCenter.default
            .addObserver(weakSelf,
                         selector: #selector(weakSelf.playerDidFinishPlaying),
                         name: .AVPlayerItemDidPlayToEndTime,
                         object: player.currentItem
            )

          weakSelf.videoDetectTimer?.invalidate()
          weakSelf.videoDetectTimer = Timer.scheduledTimer(
            withTimeInterval: weakSelf.inferenceIntervalMs / 1000,
            repeats: true, block: { _ in
              let currentTime: CMTime = player.currentTime()
              let index = Int(currentTime.seconds * 1000 / weakSelf.inferenceIntervalMs)
              guard let result = result,
                    index < result.objectDetectorResults.count else { return }
              DispatchQueue.main.async {
                weakSelf.drawAfterPerformingCalculations(
                  onDetections: result.objectDetectorResults[index]?.detections ?? [], orientation: .up,
                  withImageSize: result.size)
              }
          })
        }
      }
    }
  }

  @objc func playerDidFinishPlaying(note: NSNotification) {
    videoDetectTimer?.invalidate()
    videoDetectTimer = nil
  }

  // MARK: Handle ovelay function
  /**
   This method takes the results, translates the bounding box rects to the current view, draws the bounding boxes, classNames and confidence scores of inferences.
   */
  private func drawAfterPerformingCalculations(onDetections detections: [Detection], orientation: UIImage.Orientation, withImageSize imageSize: CGSize) {

    self.overlayView.objectOverlays = []
    self.overlayView.setNeedsDisplay()

    guard !detections.isEmpty else {
      return
    }

    var objectOverlays: [ObjectOverlay] = []
    var index = 0
    for detection in detections {
      index += 1

      guard let category = detection.categories.first else { continue }

      // Translates bounding box rect to current view.
      var viewWidth = overlayView.bounds.size.width
      var viewHeight = overlayView.bounds.size.height
      var originX: CGFloat = 0
      var originY: CGFloat = 0

      if viewWidth / viewHeight > imageSize.width / imageSize.height {
        viewHeight = imageSize.height / imageSize.width  * overlayView.bounds.size.width
        originY = (overlayView.bounds.size.height - viewHeight) / 2
      } else {
        viewWidth = imageSize.width / imageSize.height * overlayView.bounds.size.height
        originX = (overlayView.bounds.size.width - viewWidth) / 2
      }
      var convertedRect = detection.boundingBox

      switch orientation {
      case .left:
        convertedRect = CGRect(
          x: convertedRect.origin.y, y: imageSize.height - convertedRect.origin.x - convertedRect.width, width: convertedRect.height, height: convertedRect.width)
      case .right:
        convertedRect = CGRect(
          x: imageSize.width - convertedRect.origin.y - convertedRect.height, y: convertedRect.origin.x, width: convertedRect.height, height: convertedRect.width)
      default:
        break
      }

      convertedRect = convertedRect
        .applying(CGAffineTransform(scaleX: viewWidth / imageSize.width, y: viewHeight / imageSize.height))
        .applying(CGAffineTransform(translationX: originX, y: originY))

      if convertedRect.origin.x < 0 && convertedRect.origin.x + convertedRect.size.width > edgeOffset {
        convertedRect.size.width += (convertedRect.origin.x - edgeOffset)
        convertedRect.origin.x = edgeOffset
      }

      if convertedRect.origin.y < 0 && convertedRect.origin.y + convertedRect.size.height > edgeOffset {
        convertedRect.size.height += (convertedRect.origin.y - edgeOffset)
        convertedRect.origin.y = edgeOffset
      }

      if convertedRect.maxY > self.overlayView.bounds.maxY {
        convertedRect.size.height = self.overlayView.bounds.maxY - convertedRect.origin.y - self.edgeOffset
      }

      if convertedRect.maxX > self.overlayView.bounds.maxX {
        convertedRect.size.width = self.overlayView.bounds.maxX - convertedRect.origin.x - self.edgeOffset
      }

      // if index = 0 class name is unknow

      let confidenceValue = Int(category.score * 100.0)
      let string = "\(category.categoryName ?? "Unknow")  (\(confidenceValue)%)"

      let displayColor = labelColors[index % labelColors.count]

      let size = string.size(withAttributes: [.font: displayFont])

      let objectOverlay = ObjectOverlay(name: string, borderRect: convertedRect, nameStringSize: size, color: displayColor, font: self.displayFont)

      objectOverlays.append(objectOverlay)
    }

    // Hands off drawing to the OverlayView
    self.draw(objectOverlays: objectOverlays)

  }

  /** Calls methods to update overlay view with detected bounding boxes and class names.
   */
  private func draw(objectOverlays: [ObjectOverlay]) {

    self.overlayView.objectOverlays = objectOverlays
    self.overlayView.setNeedsDisplay()
  }
}

// MARK: UIImagePickerControllerDelegate, UINavigationControllerDelegate
extension ViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
  func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
    picker.dismiss(animated: true)
    if info[.mediaType] as? String == UTType.movie.identifier {
      guard let mediaURL = info[.mediaURL] as? URL else { return }
      imageEmptyLabel.isHidden = true
      processVideo(url: mediaURL)
    } else {
      guard let image = info[.originalImage] as? UIImage else { return }
      imageEmptyLabel.isHidden = true
      if runningMode != .image {
        runningMode = .image
      }
      removePlayerViewController()
      previewView.image = image
      // Pass the uiimage to mediapipe
      backgroundQueue.async {
        let result = self.objectDetectorHelper?.detect(image: image)
        // Display results by handing off to the InferenceViewController.
        self.inferenceViewController?.result = result
        DispatchQueue.main.async {
          self.inferenceViewController?.updateData()
          if let objectDetectorResult = result?.objectDetectorResults.first {
            self.drawAfterPerformingCalculations(onDetections: objectDetectorResult?.detections ?? [], orientation: image.imageOrientation, withImageSize: image.size)
          }
        }
      }
    }
  }
}

// MARK: CameraFeedManagerDelegate Methods
extension ViewController: CameraFeedManagerDelegate {

  func didOutput(sampleBuffer: CMSampleBuffer, orientation: UIImage.Orientation) {
    let currentTimeMs = Date().timeIntervalSince1970 * 1000
    // Pass the pixel buffer to mediapipe
    backgroundQueue.async { [weak self] in
      self?.objectDetectorHelper?.detectAsync(videoFrame: sampleBuffer, orientation: orientation, timeStamps: Int(currentTimeMs))
    }
  }

  // MARK: Session Handling Alerts
  func sessionWasInterrupted(canResumeManually resumeManually: Bool) {

    // Updates the UI when session is interupted.
    if resumeManually {
      self.resumeButton.isHidden = false
    } else {
      self.cameraUnavailableLabel.isHidden = false
    }
  }

  func sessionInterruptionEnded() {
    // Updates UI once session interruption has ended.
    if !self.cameraUnavailableLabel.isHidden {
      self.cameraUnavailableLabel.isHidden = true
    }

    if !self.resumeButton.isHidden {
      self.resumeButton.isHidden = true
    }
  }

  func sessionRunTimeErrorOccured() {
    // Handles session run time error by updating the UI and providing a button if session can be
    // manually resumed.
    self.resumeButton.isHidden = false
    previewView.shouldUseClipboardImage = true
  }

  func presentCameraPermissionsDeniedAlert() {
    let alertController = UIAlertController(
      title: "Camera Permissions Denied",
      message:
        "Camera permissions have been denied for this app. You can change this by going to Settings",
      preferredStyle: .alert)

    let cancelAction = UIAlertAction(title: "Cancel", style: .cancel, handler: nil)
    let settingsAction = UIAlertAction(title: "Settings", style: .default) { (action) in
      UIApplication.shared.open(
        URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
    }
    alertController.addAction(cancelAction)
    alertController.addAction(settingsAction)

    present(alertController, animated: true, completion: nil)

    previewView.shouldUseClipboardImage = true
  }

  func presentVideoConfigurationErrorAlert() {
    let alert = UIAlertController(
      title: "Camera Configuration Failed", message: "There was an error while configuring camera.",
      preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

    self.present(alert, animated: true)
    previewView.shouldUseClipboardImage = true
  }
}

// MARK: ObjectDetectorHelperDelegate
extension ViewController: ObjectDetectorHelperDelegate {
  func objectDetectorHelper(_ objectDetectorHelper: ObjectDetectorHelper, didFinishDetection result: ResultBundle?, error: Error?) {
    DispatchQueue.main.async {
      self.inferenceViewController?.result = result
      self.inferenceViewController?.updateData()
      if let objectDetectorResult = result?.objectDetectorResults.first,
         self.runningModeTabbar.selectedItem == self.cameraTabbarItem {
        self.drawAfterPerformingCalculations(onDetections: objectDetectorResult?.detections ?? [], orientation: self.cameraCapture.orientation, withImageSize: self.cameraCapture.videoFrameSize)
      }
    }
  }
}

// MARK: InferenceViewControllerDelegate Methods
extension ViewController: InferenceViewControllerDelegate {
  func viewController(
    _ viewController: InferenceViewController,
    needPerformActions action: InferenceViewController.Action
  ) {
    var isModelNeedsRefresh = false
    switch action {
    case .changeScoreThreshold(let scoreThreshold):
      if self.scoreThreshold != scoreThreshold {
        isModelNeedsRefresh = true
      }
      self.scoreThreshold = scoreThreshold
    case .changeMaxResults(let maxResults):
      if self.maxResults != maxResults {
        isModelNeedsRefresh = true
      }
      self.maxResults = maxResults
    case .changeModel(let model):
      if self.model != model {
        isModelNeedsRefresh = true
      }
      self.model = model
    case .changeBottomSheetViewBottomSpace(let isExpand):
      bottomSheetViewBottomSpace.constant = isExpand ? 0 : -inferenceBottomHeight + expandButtonHeight
      UIView.animate(withDuration: 0.3) {
        self.view.layoutSubviews()
      }
    }
    if isModelNeedsRefresh {
      objectDetectorHelper = ObjectDetectorHelper(
        model: self.model,
        maxResults: self.maxResults,
        scoreThreshold: self.scoreThreshold,
        runningMode: self.runningMode,
        delegate: self
      )
    }
  }
}

// MARK: UITabBarDelegate
extension ViewController: UITabBarDelegate {
  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    switch item {
    case cameraTabbarItem:
      if runningMode != .liveStream {
        runningMode = .liveStream
      }
      removePlayerViewController()
    #if !targetEnvironment(simulator)
      cameraCapture.checkCameraConfigurationAndStartSession()
    #endif
      previewView.shouldUseClipboardImage = false
      addImageButton.isHidden = true
      imageEmptyLabel.isHidden = true
    case photoTabbarItem:
#if !targetEnvironment(simulator)
      cameraCapture.stopSession()
#endif
      previewView.shouldUseClipboardImage = true
      addImageButton.isHidden = false
      if previewView.image == nil || playerViewController.parent != self {
        imageEmptyLabel.isHidden = false
      }
    default:
      break
    }
    overlayView.objectOverlays = []
    overlayView.setNeedsDisplay()
  }
}

// MARK: Define default constants
enum DefaultConstants {
  static let maxResults = 3
  static let scoreThreshold: Float = 0.2
  static let model: Model = .efficientdetLite0
}

// MARK: Model
enum Model: String, CaseIterable {
    case efficientdetLite0 = "EfficientDet-Lite0"
    case efficientdetLite2 = "EfficientDet-Lite2"

    var modelPath: String? {
        switch self {
        case .efficientdetLite0:
            return Bundle.main.path(
                forResource: "efficientdet_lite0", ofType: "tflite")
        case .efficientdetLite2:
            return Bundle.main.path(
                forResource: "efficientdet_lite2", ofType: "tflite")
        }
    }
}
