//
//  freexkcdApp.swift
//  freexkcd
//
//  Created by Scott Odle on 9/30/22.
//

import RealmSwift
import SwiftUI
import PDFKit
import BackgroundTasks
import UserNotifications

func scheduleAppRefresh() {
    print("scheduling refresh")
    let request = BGAppRefreshTaskRequest(identifier: "CHECK_NEW_COMIC")
    request.earliestBeginDate = .now.addingTimeInterval(3600)
    do {
        try BGTaskScheduler.shared.submit(request)
        print("refresh scheduled - \(request.earliestBeginDate!)")
    } catch {
        print("refresh schedule failed - \(error)")
    }
}

@main
struct freexkcdApp: SwiftUI.App {
    @Environment(\.scenePhase) private var phase
    
    var body: some Scene {
        WindowGroup {
            MainView()
                .environment(\.realmConfiguration, Realm.Configuration(schemaVersion: 2))
                .onAppear {
                    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { success, _ in
                        if success {
                            scheduleAppRefresh()
                        }
                    }
                }
        }.backgroundTask(.appRefresh("CHECK_NEW_COMIC")) {
            if let realm = try? Realm() {
                if let lastKnownComicNum = realm.objects(XkComic.self).max(of: \.num) {
                    xkGetComicMetadata { latestComic, _ in
                        if let latestComic = latestComic {
                            print("latest: \(latestComic.num) - last known: \(lastKnownComicNum)")
                            if latestComic.num > lastKnownComicNum {
                                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { success, _ in
                                    if success {
                                        let content = UNMutableNotificationContent()
                                        content.title = "New xkcd comic!"
                                        content.subtitle = "\(latestComic.num) - \(latestComic.title)"
                                        content.sound = .default
                                        
                                        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
                                        let request = UNNotificationRequest(identifier: latestComic.numString, content: content, trigger: trigger)
                                        
                                        UNUserNotificationCenter.current().add(request)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }.onChange(of: phase) { newPhase in
            switch newPhase {
            case .background: scheduleAppRefresh()
            default: break
            }
        }
    }
}

struct MainView : View {
    @State var selectedComic: XkComic?
    var navigationTitle: String {
        if let selectedComic = selectedComic {
            return "\(selectedComic.num) - \(selectedComic.title)"
        } else {
            return "freexkcd"
        }
    }
    
    var body: some View {
        NavigationSplitView {
            ComicsListView(selectedComic: $selectedComic)
                .navigationTitle("freexkcd")
        } detail: {
            if let selectedComic = selectedComic {
                ComicDetailView(selectedComic: selectedComic)
                    .navigationTitle(navigationTitle)
            } else {
                EmptyView()
            }
        }
    }
}

struct ComicViewport : UIViewRepresentable {
    let comic: XkComic
    
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        return view
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        comic.getImage { image in
            let document = PDFDocument()
            if let page = PDFPage(image: image) {
                document.insert(page, at: 0)
                uiView.document = document
                uiView.autoScales = true
            }
        }
    }
}

struct ComicDetailView : View {
    @StateRealmObject var selectedComic: XkComic
    
    @State var showAlt: Bool = false
    
    var body: some View {
        VStack {
            ComicViewport(comic: selectedComic)
                .onAppear {
                    if selectedComic.isUnread {
                        if let thawedComic = selectedComic.thaw() {
                            thawedComic.isUnread = false
                        }
                    }
                }
        }.frame(maxHeight: .infinity)
        HStack {
            Button("Alt") {
                showAlt = true
            }.alert(isPresented: $showAlt) {
                Alert(
                    title: Text("Alt Text"),
                    message: Text(selectedComic.alt),
                    dismissButton: .default(Text("Dismiss")) {
                        showAlt = false
                    }
                )
            }.padding()
            Button {
                selectedComic.toggleFavorite()
            } label: {
                Image(systemName: selectedComic.isFavorite ? "heart.fill" : "heart")
            }.padding()
        }.padding()
    }
}

struct ComicsList: View {
    var comics: Results<XkComic>
    @Binding var selectedComic: XkComic?
    @Binding var filterToFavorites: Bool
    
    var body: some View {
        List(
            filterToFavorites ? comics.where {
                $0.isFavorite == true
            }.sorted(by: \.num, ascending: false) : comics.sorted(by: \.num, ascending: false),
            selection: $selectedComic
        ) { comic in
            HStack {
                Text(comic.numString)
                    .foregroundColor(comic.isUnread ? .accentColor : .primary)
                Text(comic.title)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding()
                Image(systemName: comic.isFavorite ? "heart.fill" : "heart")
                Image(systemName: "chevron.forward")
            }
            .contentShape(Rectangle())
            .gesture(TapGesture(count: 1).onEnded({
                selectedComic = comic
            })).highPriorityGesture(TapGesture(count: 2).onEnded({
                comic.toggleFavorite()
            }))
        }
    }
}

struct ComicsListView: View {
    @Binding var selectedComic: XkComic?
    @State var filterToFavorites: Bool = false
    @ObservedResults(XkComic.self, sortDescriptor: SortDescriptor(keyPath: "num", ascending: false)) var comics
    
    var body: some View {
        if comics.count > 0 {
            ComicsList(comics: comics, selectedComic: $selectedComic, filterToFavorites: $filterToFavorites).onAppear {
                if let latestComic = comics.sorted(by: \.num, ascending: false).first {
                    loadComics(since: latestComic.num)
                }
            }.refreshable {
                if let latestComic = comics.sorted(by: \.num, ascending: false).first {
                    loadComics(since: latestComic.num)
                }
            }.toolbar {
                Toggle("Favorites", isOn: $filterToFavorites)
            }
        } else {
            Text("Loading comics...").onAppear {
                loadComics()
            }
        }
    }
    
    func loadComics(since lastComicLoaded: Int = 0, markUnread: Bool = false) {
        xkGetComicMetadata { latestComic, error in
            if let error = error {
                print("Error: latest - \(error)")
            } else if let latestComic = latestComic {
                if latestComic.num > lastComicLoaded {
                    if markUnread {
                        latestComic.isUnread = true
                    }
                    self.$comics.append(latestComic)
                    stride(from: latestComic.num - 1, to: lastComicLoaded, by: -1).forEach { num in
                        xkGetComicMetadata(num: num) { comic, error in
                            if let error = error {
                                print("Error: \(num) - \(error)")
                            } else if let comic = comic {
                                self.$comics.append(comic)
                            }
                        }
                    }
                }
            }
        }
    }
}
