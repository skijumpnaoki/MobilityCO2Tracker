import SwiftUI
import FirebaseAuth

struct LoginView: View {
    @EnvironmentObject var navigationManager: NavigationManager
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isSignUp: Bool = false // サインアップモードかどうか

    var body: some View {
        ZStack {
            PixelWorldBackground()
            VStack(spacing: 20) {
                Text(isSignUp ? "アカウント作成" : "ログイン")
                    .font(.custom("PixelMplus12-Regular", size: 24))
                    .foregroundColor(.white)

                // エラーメッセージ表示
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.custom("PixelMplus12-Regular", size: 16))
                        .padding(.horizontal)
                }

                // メールアドレス入力
                TextField("メールアドレス", text: $email)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .autocapitalization(.none)
                    .keyboardType(.emailAddress)
                    .padding(.horizontal)
                    .foregroundColor(.black)
                    .background(Color.white)
                    .cornerRadius(8)

                // パスワード入力
                SecureField("パスワード", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                    .foregroundColor(.black)
                    .background(Color.white)
                    .cornerRadius(8)

                // ログインボタン
                Button(action: {
                    if isSignUp {
                        signUp()
                    } else {
                        signIn()
                    }
                }) {
                    Text(isSignUp ? "アカウント作成" : "ログイン")
                        .font(.custom("PixelMplus12-Regular", size: 18))
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color(hex: "#2ECC71"))
                        .cornerRadius(10)
                }
                .padding(.horizontal)

                // モード切り替えボタン
                Button(action: {
                    isSignUp.toggle()
                    errorMessage = nil
                    email = ""
                    password = ""
                }) {
                    Text(isSignUp ? "ログイン画面へ" : "アカウント作成はこちら")
                        .font(.custom("PixelMplus12-Regular", size: 16))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .padding()
        }
        .ignoresSafeArea()
    }

    private func signIn() {
        Auth.auth().signIn(withEmail: email, password: password) { result, error in
            if let error = error {
                errorMessage = error.localizedDescription
                print("ログインエラー: \(error)")
                return
            }
            print("ログイン成功: \(result?.user.uid ?? "不明")")
            errorMessage = nil
            navigationManager.selectedTab = .tracker // ログイン後にトラッカーに遷移
        }
    }

    private func signUp() {
        Auth.auth().createUser(withEmail: email, password: password) { result, error in
            if let error = error {
                errorMessage = error.localizedDescription
                print("アカウント作成エラー: \(error)")
                return
            }
            print("アカウント作成成功: \(result?.user.uid ?? "不明")")
            errorMessage = nil
            navigationManager.selectedTab = .tracker // アカウント作成後にトラッカーに遷移
        }
    }
}

struct LoginView_Previews: PreviewProvider {
    static var previews: some View {
        LoginView()
            .environmentObject(NavigationManager())
    }
}
