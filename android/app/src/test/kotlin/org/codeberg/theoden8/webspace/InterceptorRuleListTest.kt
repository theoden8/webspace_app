// JVM unit test for the interceptor outliving a settings write (CB-003). The
// webview plugin calls a handler's checkUrl only while its rule list reads
// non-empty, and InAppWebView.setSettings clears that list on every write.
// The app writes its options right after a site's view is attached, so a
// cleared list left every Android site with no sub-resource blocking and a
// stats banner that counted only the page's own navigations.
package org.codeberg.theoden8.webspace

import org.junit.Assert.assertFalse
import org.junit.Test

class InterceptorRuleListTest {

    private val attached = FastSubresourceInterceptor(
        dnsBlocklist = DnsHostBlocklist(),
        cdnTables = LocalCdnTables(),
        onBlockChecked = {},
        onCdnReplaced = {},
    )

    @Test
    fun aSettingsWrite_leavesTheInterceptorCalled_CB003() {
        // What InAppWebView.setSettings does with the contentBlockers it is
        // sent, the app's being none.
        attached.getRuleList().clear()
        assertFalse(attached.getRuleList().isEmpty())
    }
}
