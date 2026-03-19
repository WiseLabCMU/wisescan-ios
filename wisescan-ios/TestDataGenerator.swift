import Foundation
import ARKit
import UIKit

// MARK: - Test Data Generator Fallback

class TestDataGenerator {
    // Default dimensions matching typical iPhone wide-angle AR camera
    static let defaultW = 1920
    static let defaultH = 1440
    static let totalFrames = 36 // 36 frames for a full 360-degree loop (10 degrees per frame)
    
    static func intrinsics(w: Int, h: Int) -> (fx: Float, fy: Float, cx: Float, cy: Float) {
        // Approximate intrinsics: focal length ~75% of width (typical wide-angle AR camera)
        let fx = Float(w) * 0.75
        let fy = fx
        let cx = Float(w) / 2.0
        let cy = Float(h) / 2.0
        return (fx, fy, cx, cy)
    }
    
    // Virtual Green Box (1 meter wide) floating at origin
    static let boxSize: Float = 0.5
    static let radius: Float = 2.0
    
    // A simple 3D box centered at origin
    static let vertices: [simd_float4] = [
        simd_float4(-boxSize, -boxSize, -boxSize, 1),
        simd_float4( boxSize, -boxSize, -boxSize, 1),
        simd_float4( boxSize,  boxSize, -boxSize, 1),
        simd_float4(-boxSize,  boxSize, -boxSize, 1),
        simd_float4(-boxSize, -boxSize,  boxSize, 1),
        simd_float4( boxSize, -boxSize,  boxSize, 1),
        simd_float4( boxSize,  boxSize,  boxSize, 1),
        simd_float4(-boxSize,  boxSize,  boxSize, 1)
    ]
    
    static func generatePoseAndIntrinsics(for index: Int, w: Int = defaultW, h: Int = defaultH) -> (simd_float4x4, simd_float3x3) {
        let frameIndex = index % totalFrames
        let angle = Float(frameIndex) * 2.0 * .pi / Float(totalFrames)
        let camX = sin(angle) * radius
        let camZ = cos(angle) * radius
        let camY: Float = 0.5

        let forward = simd_normalize(simd_float3(-camX, -camY, -camZ))
        let worldUp = simd_float3(0, 1, 0)
        let right = simd_normalize(simd_cross(worldUp, forward))
        let up = simd_cross(forward, right)

        var mat = matrix_identity_float4x4
        mat.columns.0 = simd_float4(right, 0)
        mat.columns.1 = simd_float4(up, 0)
        mat.columns.2 = simd_float4(-forward, 0) // ARKit camera space (-Z forward)
        mat.columns.3 = simd_float4(camX, camY, camZ, 1)
        
        let (fx, fy, cx, cy) = intrinsics(w: w, h: h)
        let intrinsicsMat = simd_float3x3(
            simd_float3(fx, 0, 0),
            simd_float3(0, fy, 0),
            simd_float3(cx, cy, 1)
        )
        return (mat, intrinsicsMat)
    }
    
    static func generateImage(for index: Int, w: Int = defaultW, h: Int = defaultH, transform: simd_float4x4, intrinsics: simd_float3x3) -> Data {
        let frameIndex = index % totalFrames
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Draw into context
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        
        // Fill dark background
        context.setFillColor(gray: 0.15, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        
        let fx = intrinsics[0][0]
        let fy = intrinsics[1][1]
        let cx = intrinsics[2][0]
        let cy = intrinsics[2][1]
        
        // Project the 3D green box into 2D screen coordinates
        let viewMat = transform.inverse
        var projPts: [CGPoint] = []
        for v in vertices {
            let vCam = viewMat * v
            if vCam.z < -0.1 { // Camera looks down -Z
                let px = CGFloat(fx * (vCam.x / -vCam.z) + cx)
                // CoreGraphics drawing is Y-up, but projection assumes UI Y-down.
                // We'll flip Y for CoreGraphics rasterization.
                let py = CGFloat(Float(h) - (fy * (vCam.y / -vCam.z) + cy))
                projPts.append(CGPoint(x: px, y: py))
            }
        }
        
        if projPts.count >= 3 {
            context.setFillColor(red: 0, green: 0.8, blue: 0, alpha: 1.0)
            context.setStrokeColor(red: 0, green: 1.0, blue: 0, alpha: 1.0)
            context.setLineWidth(2.0)
            
            // Draw a rough polygon enclosing points (simple hack instead of proper convex hull)
            let path = CGMutablePath()
            // To prevent chaotic crossing lines, sort points by angle around centroid
            let centroidX = projPts.reduce(0) { $0 + $1.x } / CGFloat(projPts.count)
            let centroidY = projPts.reduce(0) { $0 + $1.y } / CGFloat(projPts.count)
            let sortedPts = projPts.sorted { p1, p2 in
                atan2(p1.y - centroidY, p1.x - centroidX) < atan2(p2.y - centroidY, p2.x - centroidX)
            }
            
            path.move(to: sortedPts[0])
            for pt in sortedPts.dropFirst() {
                path.addLine(to: pt)
            }
            path.closeSubpath()
            context.addPath(path)
            context.drawPath(using: .fillStroke)
        }
        
        // Draw frame index text overlay
        let text = "Test Frame \(frameIndex)"
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.white, // Safe UIKit color
            .font: UIFont.boldSystemFont(ofSize: 24)
        ]
        UIGraphicsPushContext(context)
        (text as NSString).draw(at: CGPoint(x: 20, y: h - 50), withAttributes: attributes)
        UIGraphicsPopContext()
        
        guard let cgImage = context.makeImage() else { return Data() }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.8) ?? Data()
    }
    
    static func generateDepthMap(for index: Int, w: Int = defaultW, h: Int = defaultH) -> Data {
        // Output format expects 16-bit PNG (millimeters)
        var depthPixels = [UInt16](repeating: 2000, count: w * h) // 2.0 meters flat wall
        
        let cu = w / 2
        let cv = h / 2
        // Bounding box for the green box approximation (radius of 1/3 screen)
        let r = Int(min(w, h)) / 3
        let rSq = r * r
        
        for y in 0..<h {
            for x in 0..<w {
                let dx = x - cu
                let dy = y - cv
                if dx*dx + dy*dy <= rSq {
                    depthPixels[y * w + x] = 1500 // 1.5 meters for box
                }
            }
        }
        
        let data = Data(bytes: depthPixels, count: depthPixels.count * 2)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 16, bytesPerRow: w * 2, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            return Data()
        }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.pngData() ?? Data()
    }
}
