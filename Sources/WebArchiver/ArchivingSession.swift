//
//  ArchivingSession.swift
//  WebArchiver
//
//  Created by Ernesto Elsäßer on 15.06.19.
//  Copyright © 2019 Ernesto Elsäßer. All rights reserved.
//

import Foundation
import os

extension String {
    /// 使用正则表达式查找匹配的文本
    /// - Parameter regexPattern: 正则表达式
    /// - Returns: 查找到的匹配的文本数组
    public func groups(for regexPattern: String) -> [[String]] {
        do {
            let text = self
            let regex = try NSRegularExpression(pattern: regexPattern)
            let matches = regex.matches(in: text,
                                        range: NSRange(text.startIndex..., in: text))
            return matches.map { match in
                (0 ..< match.numberOfRanges).map {
                    let rangeBounds = match.range(at: $0)
                    guard let range = Range(rangeBounds, in: text) else {
                        return ""
                    }
                    return String(text[range])
                }
            }
        } catch {
            print("invalid regex: \(error.localizedDescription)")
            return []
        }
    }
}

class ArchivingSession {
    
    static var encoder: PropertyListEncoder = {
        let plistEncoder = PropertyListEncoder()
        plistEncoder.outputFormat = .binary
        return plistEncoder
    }()
    
    private let urlSession: URLSession
    private let completion: (ArchivingResult) -> ()
    private let cachePolicy: URLRequest.CachePolicy
    private let cookies: [HTTPCookie]
    private var errors: [Error] = []
    private var pendingTaskCount: Int = 0
    
    init(cachePolicy: URLRequest.CachePolicy, cookies: [HTTPCookie], completion: @escaping (ArchivingResult) -> ()) {
        let sessionQueue = OperationQueue()
        sessionQueue.maxConcurrentOperationCount = 1
        sessionQueue.name = "WebArchiverWorkQueue"
        self.urlSession = URLSession(configuration: .ephemeral, delegate: nil, delegateQueue: sessionQueue)
        self.cachePolicy = cachePolicy
        self.cookies = cookies
        self.completion = completion
    }

    /// 可能需要分析头部声明，确定字符串编码
       /// - Parameter response: HTTPURLResponse
       /// - Returns: 推断该使用的文本编码
       func extractEncoding(from response: HTTPURLResponse) -> String.Encoding {
           guard let contenType = response.allHeaderFields["Content-Type"] as? String,
               let matches = contenType.groups(for: "^text/.+charset=(.+)$").first, matches.count == 2 else {
               return .utf8
           }
           let charset = matches[1].lowercased()
           var result: String.Encoding
           switch charset {
           case "utf-8":
               result = .utf8
           case "gb18030", "gbk":
               result = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
           case "gb2312":
               result = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_2312_80.rawValue)))
           default:
               // 特殊的编码，这里需要特殊处理，碰到再说
            if #available(iOS 12.0, *) {
                os_log(.debug, "HTML Encoding: %@", charset)
            }
               result = .utf8
           }
           return result
       }
    
    func load(url: URL, fallback: WebArchive?, expand: @escaping (WebArchiveResource) throws -> WebArchive ) {
        pendingTaskCount = pendingTaskCount + 1
        var request = URLRequest(url: url)
        request.cachePolicy = cachePolicy
        urlSession.configuration.httpCookieStorage?.setCookies(cookies, for: url, mainDocumentURL: nil)
        
        let task = urlSession.dataTask(with: request) { (data, response, error) in
            self.pendingTaskCount = self.pendingTaskCount - 1
            
            var archive = fallback
            if let error = error {
                self.errors.append(ArchivingError.requestFailed(resource: url, error: error))
            } else if let data = data, let response = response as? HTTPURLResponse, let mimeType = response.mimeType {
                let encoding = self.extractEncoding(from: response)
                let resource = WebArchiveResource(url: url, data: data, mimeType: mimeType, encoding: encoding)
                do {
                    archive = try expand(resource)
                } catch {
                    self.errors.append(error)
                }
            } else {
                self.errors.append(ArchivingError.invalidResponse(resource: url))
            }
            
            self.finish(with: archive)
        }
        task.resume()
    }
    
    private func finish(with archive: WebArchive?) {
        
        guard self.pendingTaskCount == 0 else {
            return
        }
        
        var plistData: Data?
        if let archive = archive {
            do {
                plistData = try ArchivingSession.encoder.encode(archive)
            } catch {
                errors.append(error)
            }
        }
        
        let result = ArchivingResult(plistData: plistData, errors: errors)
        DispatchQueue.main.async {
            self.completion(result)
        }
    }
}
