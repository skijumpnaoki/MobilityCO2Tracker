import SwiftUI
import FirebaseAuth
import FirebaseCore

// MARK: - Navigation Manager
class NavigationManager: ObservableObject {
    @Published var selectedTab: Tab = .tracker
    @Published var showMenu: Bool = false
    
    enum Tab {
        case tracker
        case story
    }
}

// MARK: - Content View with Menu
struct ContentView: View {
    @EnvironmentObject var navigationManager: NavigationManager
    @State private var user: User? // ログイン中のユーザー

    var body: some View {
        ZStack {
            // ログイン状態に応じて表示を切り替え
            if user == nil {
                LoginView()
                    .onAppear {
                        // ログイン状態を監視
                        _ = Auth.auth().addStateDidChangeListener { _, user in
                            self.user = user
                            if user != nil {
                                print("User logged in: \(user!.uid)")
                            } else {
                                print("User logged out")
                            }
                        }
                    }
            } else {
                // ログイン済みの場合、メイン画面を表示
                switch navigationManager.selectedTab {
                case .tracker:
                    ReportView()
                case .story:
                    StoryView()
                }
                
                // サイドメニュー
                GeometryReader { geometry in
                    HStack {
                        VStack(alignment: .leading, spacing: 0) {
                            // メニューヘッダー
                            HStack {
                                Text("メニュー")
                                    .font(.custom("PixelMplus12-Regular", size: 24))
                                    .foregroundColor(.white)
                                    .padding(.leading, 20)
                                    .padding(.top, 60)
                                Spacer()
                                Button(action: {
                                    withAnimation {
                                        navigationManager.showMenu = false
                                    }
                                }) {
                                    Image(systemName: "xmark")
                                        .foregroundColor(.white)
                                        .padding(10)
                                        .background(Circle().fill(Color(hex: "#2ECC71")))
                                        .padding(.trailing, 20)
                                        .padding(.top, 60)
                                }
                            }
                            
                            // メニュー項目：トラッカー
                            Button(action: {
                                withAnimation {
                                    navigationManager.selectedTab = .tracker
                                    navigationManager.showMenu = false
                                }
                            }) {
                                HStack {
                                    Image(systemName: "chart.bar")
                                        .foregroundColor(.white)
                                        .frame(width: 30)
                                    Text("トラッカー")
                                        .font(.custom("PixelMplus12-Regular", size: 20))
                                        .foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 15)
                                .background(navigationManager.selectedTab == .tracker ? Color(hex: "#2ECC71").opacity(0.8) : Color.clear)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal, 10)
                            
                            // メニュー項目：ストーリー
                            Button(action: {
                                withAnimation {
                                    navigationManager.selectedTab = .story
                                    navigationManager.showMenu = false
                                }
                            }) {
                                HStack {
                                    Image(systemName: "book.fill")
                                        .foregroundColor(.white)
                                        .frame(width: 30)
                                    Text("ストーリー")
                                        .font(.custom("PixelMplus12-Regular", size: 20))
                                        .foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 15)
                                .background(navigationManager.selectedTab == .story ? Color(hex: "#2ECC71").opacity(0.8) : Color.clear)
                                .cornerRadius(10)
                            }
                            .padding(.horizontal, 10)
                            
                            // ログアウトボタン
                            Button(action: {
                                do {
                                    try Auth.auth().signOut()
                                    navigationManager.showMenu = false
                                } catch {
                                    print("ログアウトエラー: \(error)")
                                }
                            }) {
                                HStack {
                                    Image(systemName: "arrow.right.circle.fill")
                                        .foregroundColor(.white)
                                        .frame(width: 30)
                                    Text("ログアウト")
                                        .font(.custom("PixelMplus12-Regular", size: 20))
                                        .foregroundColor(.white)
                                    Spacer()
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 15)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(10)
                            }
                            .padding(.horizontal, 10)
                            
                            Spacer()
                        }
                        .frame(width: geometry.size.width * 0.75)
                        .background(
                            ZStack {
                                Color(hex: "#1A2A44")
                                ForEach(0..<10) { _ in
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 2, height: 2)
                                        .position(
                                            x: CGFloat.random(in: 0...(geometry.size.width * 0.75)),
                                            y: CGFloat.random(in: 0...geometry.size.height)
                                        )
                                }
                            }
                        )
                        .offset(x: navigationManager.showMenu ? 0 : -geometry.size.width * 0.75)
                        .animation(.easeInOut(duration: 0.3), value: navigationManager.showMenu)

                        Spacer()
                    }
                }
                .background(
                    Color.black.opacity(navigationManager.showMenu ? 0.5 : 0)
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation {
                                navigationManager.showMenu = false
                            }
                        }
                        .animation(.easeInOut, value: navigationManager.showMenu)
                )
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(NavigationManager())
    }
}
