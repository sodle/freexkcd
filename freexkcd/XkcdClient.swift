//
//  XkcdClient.swift
//  freexkcd
//
//  Created by Scott Odle on 9/30/22.
//

import Foundation
import UIKit

import Alamofire
import AlamofireImage
import RealmSwift

final class XkComic : Object, ObjectKeyIdentifiable, Codable {
    @Persisted(primaryKey: true) var num: Int
    @Persisted var year: String
    @Persisted var month: String
    @Persisted var day: String
    @Persisted var title: String
    @Persisted var alt: String
    @Persisted var img:  String
    private enum CodingKeys: String, CodingKey {
        case num, year, month, day, title, alt, img
    }
    
    @Persisted var isFavorite: Bool = false
    @Persisted var isUnread: Bool = false
    
    func toggleFavorite() {
        print("Favorite \(self.num)")
        if let realm = try? Realm() {
            do {
                if let thawedSelf = self.thaw() {
                    try realm.write({
                        thawedSelf.isFavorite = !self.isFavorite
                        print("\(self.num) - fave = \(thawedSelf.isFavorite)")
                    })
                } else {
                    print("Error: Thaw")
                }
            } catch {
                print("Error: Favorite - \(error)")
            }
        } else {
            print("Error: Realm()")
        }
    }
    
    var numString: String {
        self.num.formatted()
    }
    
    func getImage(completionHandler: @escaping (UIImage) -> Void) {
        afSession.request(self.img).responseImage { response in
            if case .success(let image) = response.result {
                completionHandler(image)
            }
        }
    }
}

enum XkError : Error {
    case failedFetchingMetadata(code: Int?, underlyingError: Error)
    case failedReadingMetadata
}

let xkBaseUrl = URL.init(string: "https://xkcd.com")!

let retryPolicy = RetryPolicy()
let afSession = Session(interceptor: retryPolicy)
func xkGetComicMetadata(num: Int? = nil, completionHandler: @escaping (XkComic?, Error?) -> Void) {
    var comicUrl = xkBaseUrl
    if let num = num {
        comicUrl = comicUrl.appending(path: String(num))
    }
    comicUrl = comicUrl.appending(path: "info.0.json")
    
    afSession.request(comicUrl).responseDecodable(of: XkComic.self) { response in
        if let error = response.error {
            completionHandler(nil, XkError.failedFetchingMetadata(code: response.response?.statusCode, underlyingError: error))
        } else if let comic = response.value {
            completionHandler(comic, nil)
        } else {
            completionHandler(nil, XkError.failedReadingMetadata)
        }
    }
}
