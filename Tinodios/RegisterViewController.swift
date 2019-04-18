//
//  RegisterViewController.swift
//  ios
//
//  Created by ztimc on 2018/12/26.
//  Copyright © 2018 Tinode. All rights reserved.
//

import Foundation
import MessageKit
import UIKit
import TinodeSDK

class RegisterViewController: UIViewController {
    @IBOutlet weak var loginText: UITextField!
    @IBOutlet weak var pwdText: UITextField!
    @IBOutlet weak var nameText: UITextField!
    @IBOutlet weak var credentialText: UITextField!
    @IBOutlet weak var signUpBtn: UIButton!
    @IBOutlet weak var loadAvatar: UIButton!
    @IBOutlet weak var avatarView: AvatarView!

    var imagePicker: ImagePicker!

    override func viewDidLoad() {
        super.viewDidLoad()

        self.imagePicker = ImagePicker(presentationController: self, delegate: self)

        // Listen to text change events to clear the possible error from eralier attempt.
        loginText.addTarget(self, action: #selector(textFieldDidChange(_:)), for: UIControl.Event.editingChanged)
        pwdText.addTarget(self, action: #selector(textFieldDidChange(_:)), for: UIControl.Event.editingChanged)
        nameText.addTarget(self, action: #selector(textFieldDidChange(_:)), for: UIControl.Event.editingChanged)
        credentialText.addTarget(self, action: #selector(textFieldDidChange(_:)), for: UIControl.Event.editingChanged)
    }

    @objc func textFieldDidChange(_ textField: UITextField) {
        UiUtils.clearTextFieldError(textField)
    }
    
    @IBAction func onLoadAvatar(_ sender: UIButton) {
        // Get avatar image
        self.imagePicker.present(from: sender)
    }

    @IBAction func onSignUp(_ sender: Any) {
        let login = UiUtils.ensureDataInTextField(loginText)
        let pwd = UiUtils.ensureDataInTextField(pwdText)
        let name = UiUtils.ensureDataInTextField(nameText)
        let credential = UiUtils.ensureDataInTextField(credentialText)

        if login == "" || pwd == "" || name == "" || credential == "" {
            return
        }

        var method: String?
        if Validate.email(credential).isRight {
            method = "email"
        }
        if Validate.phoneNum(credential).isRight {
            method = "tel"
        }
        
        guard method != nil else {
            UiUtils.markTextFieldAsError(credentialText)
            return
        }
        
        signUpBtn.isUserInteractionEnabled = false
        let tinode = Cache.getTinode()

        let avatar = UiUtils.resizeImage(image: avatarView?.image, width: 128, height: 128, clip: true)
        let vcard = VCard(fn: name, avatar: avatar)

        let desc = MetaSetDesc<VCard, String>(pub: vcard, priv: nil)
        let cred = Credential(meth: method!, val: credential)
        var creds = [Credential]()
        creds.append(cred)
        do {
            try tinode.connect(to: Cache.kHostName, useTLS: false)?
                .then(
                    onSuccess: { pkt in
                        return try tinode.createAccountBasic(uname: login, pwd: pwd, login: true, tags: nil, desc: desc, creds: creds)
                }, onFailure: nil)?
                .then(
                    onSuccess: { [weak self] msg in
                        self?.signUpBtn.isUserInteractionEnabled = true
                        if let code = msg.ctrl?.code, code >= 300 {
                            let vc = self?.storyboard?.instantiateViewController(withIdentifier: String(describing: type(of: CredentialsViewController())))
                                as! CredentialsViewController
                            
                            if let cArr = msg.ctrl!.getStringArray(for: "cred") {
                                for c in cArr {
                                    vc.meth = c
                                }
                            }
                            DispatchQueue.main.async {
                                self?.navigationController?.pushViewController(vc, animated: true)
                            }
                        } else {
                            let storyboard = UIStoryboard(name: "Main", bundle: nil)
                            let destinationVC = storyboard.instantiateViewController(withIdentifier: "ChatsNavigator") as! UINavigationController
                            
                            self?.show(destinationVC, sender: nil)
                        }
                        return nil
                    }, onFailure: nil)
            
        } catch {
            print("Failed to connect/createAccountBasic to Tinode: \(error).")
        }
    }
}

extension RegisterViewController: ImagePickerDelegate {
    func didSelect(image: UIImage?) {
        self.avatarView.image = image
    }
}
