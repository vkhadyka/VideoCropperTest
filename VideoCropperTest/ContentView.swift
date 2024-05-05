//
//  ContentView.swift
//  VideoCropperTest
//
//  Created by Vadim Khadyka on 26.09.23.
//

import SwiftUI
import AVFoundation
import Photos


struct ContentView: View {
   private var vm = VM()
    var body: some View {
        VStack {
            Image(systemName: "globe")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Hello, world!")
        }
        .padding()
        .task {
            await vm.compressVideos()
        }
    }
}

#Preview {
    ContentView()
}

class VM {
    
    func compressVideos() async {
        guard let dogsVideo = Bundle.main.url(forResource: "dogs", withExtension: "mp4"),
              let finishURL = try? await Compressor(asset: AVURLAsset(url: dogsVideo)).export(cropRect: .init(origin: .zero, size: .init(width: 100, height: 100))) else {
            return
        }
        try? await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: finishURL)
        }
    }
}



private class Compressor {
    private(set) var duration: CMTime = .zero
    private var preferredTransform: CGAffineTransform = .identity
    private var bitrate: Float = .zero
    private var frameRate: Float = .zero
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private let minHeight = 720.0
    private let minWidth = 480.0
    private let minBitrate = Float(2500000)
    private(set) var size: CGSize?
    private var totalFrames: Double = 0
    
    init(asset: AVURLAsset) {
        self.asset = asset
    }
    
    private func getVideoDuration() async throws{
        guard let asset else {
            print("Unable to get video source")
            return
        }
        duration = try await asset.load(.duration)
        
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            (preferredTransform, size, bitrate, frameRate) = try await track.load(.preferredTransform, .naturalSize, .estimatedDataRate, .nominalFrameRate)
            videoTrack = track
        }
        audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        
        totalFrames = ceil(duration.seconds * Double(frameRate))
    }
    
    func export(cropRect: CGRect = .zero, startTime: CGFloat? = nil, endTime: CGFloat? = nil) async throws -> URL? {
        
        let finalURL = URL.documentsDirectory
            .appendingPathComponent("\(UUID().uuidString)_finished.mp4", conformingTo: .video)

        
       try await getVideoDuration()
        let cropRect = cropRect.applying(preferredTransform)
        let size = size?.applying(preferredTransform)
        let outputURL: URL
        do {
            guard let asset, let size, let videoTrack else {
                print("Enable to get asset.")
                return nil
            }
        
            
            
            let assetReader = try AVAssetReader(asset: asset)
                        
            let newWidth: Int = Int(size.width)
            let newHeight: Int = Int(size.height)
            
            let videoReaderSettings: [String: AnyObject] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA) as AnyObject
            ]
            
            let assetReaderVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoReaderSettings)
            
            var assetReaderAudioOutput: AVAssetReaderTrackOutput?
            if let audioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                let audioReaderSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2
                ]
                
                assetReaderAudioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioReaderSettings)
                
                if let assetReaderAudioOutput,
                   assetReader.canAdd(assetReaderAudioOutput) {
                    assetReader.add(assetReaderAudioOutput)
                } else {
                   
                    print("Couldn't add audio output reader")
                }
            }
            
            if assetReader.canAdd(assetReaderVideoOutput) {
                assetReader.add(assetReaderVideoOutput)
            } else {
                print("Couldn't add video output reader")
            }
            
            let videoInputQueue = DispatchQueue(label: "com.videoQueue", qos: .background)
            let audioInputQueue = DispatchQueue(label: "com.audioQueue", qos: .background)
            
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: 128000
            ]
            
            let audioInput = AVAssetWriterInput(mediaType: .audio,
                                                outputSettings: audioSettings)
            let videoInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: getVideoWriterSettings(bitrate: Int(minBitrate),
                                                                                       width: newWidth,
                                                                                       height: newHeight))
            videoInput.transform = preferredTransform
            videoInput.expectsMediaDataInRealTime = true
            
            let assetWriter = try AVAssetWriter(url: finalURL, fileType: .mp4)
            
            assetWriter.shouldOptimizeForNetworkUse = true
            assetWriter.add(videoInput)
            assetWriter.add(audioInput)
            
            assetWriter.startWriting()
            assetReader.startReading()
            assetWriter.startSession(atSourceTime: .zero)
            
            let progress = Progress(totalUnitCount: Int64(totalFrames))
            var frameCount = 0
            await withCheckedContinuation { continuation in
                videoInput.requestMediaDataWhenReady(on: videoInputQueue) { [weak self] in
                    guard let self else { return }
                    
                    while videoInput.isReadyForMoreMediaData {
                     
                        
                        if let cmSampleBuffer = assetReaderVideoOutput.copyNextSampleBuffer() {
                                // Update progress based on number of processed frames
                            frameCount += 1
                            

                            let sampleBuffer = modifySampleBuffer(cmSampleBuffer, cropRect: cropRect)
                            
                            let result = videoInput.append(sampleBuffer ?? cmSampleBuffer)
                            if !result {
                                print(assetWriter.status)
                                print(assetWriter.error)
                            }
                        } else {
                            videoInput.markAsFinished()
                            return continuation.resume()
                        }
                    }
                }
            }
            
            if assetReader.status == .reading {
                await withCheckedContinuation { continuation in
                    audioInput.requestMediaDataWhenReady(on: audioInputQueue) { [weak self] in
                        guard let self else { return }
                        while audioInput.isReadyForMoreMediaData {

                            if let cmSampleBuffer = assetReaderAudioOutput?.copyNextSampleBuffer() {
                                audioInput.append(cmSampleBuffer)
                            } else {
                                audioInput.markAsFinished()
                                return continuation.resume()
                            }
                        }
                    }
                }
            }
            
            guard assetReader.status != .cancelled else { return nil }
            
            await assetWriter.finishWriting()
            assetReader.cancelReading()
        } catch {
            print(error.localizedDescription)
        }
        return finalURL
    }
    
    private func getVideoWriterSettings(bitrate: Int, width: Int, height: Int) -> [String: Any] {
        let videoWriterSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,

        ]
        
        return videoWriterSettings
    }
    
    func modifySampleBuffer(_ sampleBuffer: CMSampleBuffer, cropRect: CGRect) -> CMSampleBuffer? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        
        let ciImage = CIImage(cvImageBuffer: pixelBuffer)
        let croppedCIImage = ciImage.cropped(to: cropRect).transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
        
        var newPixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(cropRect.width), Int(cropRect.height), kCVPixelFormatType_32BGRA, nil, &newPixelBuffer)
        
        guard let outPixelBuffer = newPixelBuffer else { return nil }
        
        let context = CIContext()
        context.render(croppedCIImage, to: outPixelBuffer)
        
        var timingInfo = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo) == 0 else {
            return nil
        }
        
        var newFormatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: outPixelBuffer, formatDescriptionOut: &newFormatDescription)
        
        guard let newFormatDescription else { return nil }
        
        var newSampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: outPixelBuffer,
                                                 formatDescription: newFormatDescription,
                                                 sampleTiming: &timingInfo,
                                                 sampleBufferOut: &newSampleBuffer)
        
        return newSampleBuffer
    }
}
