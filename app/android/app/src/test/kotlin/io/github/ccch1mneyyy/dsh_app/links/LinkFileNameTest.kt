package io.github.ccch1mneyyy.dsh_app.links

import org.junit.Assert.assertEquals
import org.junit.Test

class LinkFileNameTest {
    @Test fun longShareCodeNameRetainsItsImportRoute() {
        assertEquals("a".repeat(114) + ".dshgo", LinksPlugin.safeName("a".repeat(120) + ".dshgo"))
        assertEquals("a".repeat(114) + ".DSHGO", LinksPlugin.safeName("folder/" + "a".repeat(120) + ".DSHGO"))
    }

    @Test fun shortAndExtensionlessNamesKeepTheirExistingShape() {
        assertEquals("profile.dshgo", LinksPlugin.safeName("folder/profile.dshgo"))
        assertEquals("shared", LinksPlugin.safeName("  "))
        assertEquals("a".repeat(120), LinksPlugin.safeName("a".repeat(130)))
        assertEquals("a".repeat(120), LinksPlugin.safeName("a".repeat(120) + "."))
        assertEquals("a." + "b".repeat(118), LinksPlugin.safeName("a." + "b".repeat(120)))
    }
}
