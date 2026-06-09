import AppKit

extension SephrWindowController {

    func titlebarShowsBackForward() -> Bool { true }

    @IBAction func goBack(_ sender: Any?) {
        SephrTabModel.shared.activeTab()?.webView?.goBack()
    }

    @IBAction func goForward(_ sender: Any?) {
        SephrTabModel.shared.activeTab()?.webView?.goForward()
    }

    @IBAction func reload(_ sender: Any?) {
        SephrTabModel.shared.activeTab()?.webView?.reload()
    }
}
