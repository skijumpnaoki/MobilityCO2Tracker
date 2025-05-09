import SwiftUI

struct StoryView: View {
    @EnvironmentObject var navigationManager: NavigationManager
    @State private var isPhotoVisible = false
    @State private var areButtonsVisible = false
    
    // スポンサー情報（ReportViewと同じデータを使用）
    private let sponsors = [
        Sponsor(
            id: UUID(),
            name: "よつ葉乳業",
            imageURL: "yotsuba",
            mainLink: "https://www.yotsuba.co.jp/",
            detailLink: "https://www.yotsuba.co.jp/company/"
        ),
        Sponsor(
            id: UUID(),
            name: "Traicy",
            imageURL: "traicy",
            mainLink: "https://www.traicy.com/",
            detailLink: "https://www.traicy.com/about"
        ),
        Sponsor(
            id: UUID(),
            name: "植村建設",
            imageURL: "uemura",
            mainLink: "https://www.uemurakk.co.jp/",
            detailLink: "https://www.uemurakk.co.jp/company/"
        )
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                PixelWorldBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text("プロジェクトのストーリー")
                            .font(.custom("PixelMplus12-Regular", size: 24))
                            .foregroundColor(.white)
                            .padding(.horizontal)
                        
                        Text("ピクセルくんの冒険へようこそ！")
                            .font(.custom("PixelMplus12-Regular", size: 20))
                            .foregroundColor(.white)
                            .padding(.horizontal)
                        
                        Text("""
                        このプロジェクトは、CO2排出量を“楽しく”トラッキングすることを目的に始まりました。ピクセルくんは、あなたの移動手段を記録し、どれだけ地球に優しいかを教えてくれます。

                        そして実はこのアプリ、スキージャンプ選手・中村直幹自身のリアルな挑戦から生まれました。僕は世界中を飛び回りながら、ひとつひとつのジャンプに意味を込めています。1メートル飛ぶごとにCO2オフセットを行う──そんな想いをのせて、このアプリを立ち上げました。

                        僕がアスリートとして飛ぶことで、誰かの生活が少しでも豊かになったら。そんな未来を目指して、環境に優しい移動を広げ、楽しみながらサステナビリティに貢献できる仕組みを届けたいと思っています。

                        ピクセルくんと一緒に、そして僕と一緒に、星を守る冒険に出かけましょう！
                        """)
                            .font(.custom("PixelMplus12-Regular", size: 16))
                            .foregroundColor(.white)
                            .padding(.horizontal)
                        
                        Image("pixel_kun")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 100, height: 100)
                            .padding(.horizontal)
                        
                        // 選手の写真（アイコン風）
                        Image("naoki_icon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 120, height: 120)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                            .padding(.horizontal)
                            .opacity(isPhotoVisible ? 1 : 0)
                            .onAppear {
                                withAnimation(.easeIn(duration: 1)) {
                                    isPhotoVisible = true
                                }
                            }
                        
                        // 選手の説明
                        Text("中村直幹（なかむら なおき）")
                            .font(.custom("PixelMplus12-Regular", size: 20))
                            .foregroundColor(.white)
                            .padding(.horizontal)
                        
                        Text("""
                        生年月日：1991年9月19日
                        出身地：北海道
                        主な実績：スキージャンプワールドカップ出場、国内大会での複数優勝
                        スキージャンプを通じて環境問題に取り組み、CO2オフセット活動を推進中。
                        """)
                            .font(.custom("PixelMplus12-Regular", size: 16))
                            .foregroundColor(.white)
                            .padding(.horizontal)
                        
                        // リンクボタン
                        VStack(spacing: 15) {
                            LinkButton(
                                title: "YouTubeチャンネル",
                                icon: "play.circle.fill",
                                url: "https://www.youtube.com/@naokinakamura0919"
                            )
                            LinkButton(
                                title: "オンラインサロン",
                                icon: "person.3.fill",
                                url: "https://lounge.dmm.com/detail/6702/"
                            )
                            LinkButton(
                                title: "公式ウェブサイト",
                                icon: "globe",
                                url: "https://www.flyinglaboratory.com/"
                            )
                        }
                        .padding(.horizontal)
                        .opacity(areButtonsVisible ? 1 : 0)
                        .onAppear {
                            withAnimation(.easeIn(duration: 1).delay(0.5)) {
                                areButtonsVisible = true
                            }
                        }
                        
                        // スポンサー企業セクション
                        VStack(alignment: .leading) {
                            Text("サスティナブルスポンサー企業")
                                .font(.custom("PixelMplus12-Regular", size: 20))
                                .foregroundColor(.white)
                                .padding(.horizontal)
                            
                            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                                ForEach(sponsors) { sponsor in
                                    VStack {
                                        Image(sponsor.imageURL)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(height: 60)
                                            .cornerRadius(8)
                                        Text(sponsor.name)
                                            .foregroundColor(.white)
                                            .font(.custom("PixelMplus12-Regular", size: 14))
                                            .multilineTextAlignment(.center)
                                    }
                                    .padding(8)
                                    .background(Color(hex: "#2A3A54"))
                                    .cornerRadius(12)
                                    .onTapGesture {
                                        if let url = URL(string: sponsor.mainLink) {
                                            UIApplication.shared.open(url)
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.vertical)
                    }
                    .padding(.vertical)
                }
            }
            .navigationTitle("ストーリー")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        navigationManager.showMenu.toggle()
                    }) {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.white)
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

// リンクボタンのカスタムビュー
struct LinkButton: View {
    let title: String
    let icon: String
    let url: String
    
    var body: some View {
        Button(action: {
            if let url = URL(string: url) {
                UIApplication.shared.open(url)
            }
        }) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(.white)
                    .frame(width: 30)
                Text(title)
                    .font(.custom("PixelMplus12-Regular", size: 16))
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding()
            .background(Color(hex: "#2ECC71").opacity(0.8))
            .cornerRadius(10)
        }
    }
}

struct StoryView_Previews: PreviewProvider {
    static var previews: some View {
        StoryView()
            .environmentObject(NavigationManager())
    }
}
