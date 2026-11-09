package app.orb.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingLinkTest {
    private val token = "A".repeat(43)

    @Test fun parsesValidLink() {
        val p = PairingLink.parse("orb://parear?host=100.101.102.103&port=47821&token=$token&mac=Mac%20do%20Thiago")
        assertEquals("100.101.102.103", p.host)
        assertEquals(47821, p.port)
        assertEquals(token, p.token)
        assertEquals("Mac do Thiago", p.mac)
    }

    @Test fun trimsWhitespaceAndAcceptsTokenAlphabet() {
        val t = "a-_Z".repeat(10) + "abc"
        val p = PairingLink.parse("  orb://parear?host=mac.tail1234.ts.net&port=1&token=$t \n")
        assertEquals("mac.tail1234.ts.net", p.host)
        assertEquals(1, p.port)
    }

    @Test fun decodesUrlEncodedFields() {
        val p = PairingLink.parse("orb://parear?host=%31%30%30.1.2.3&port=47821&token=$token&mac=Caf%C3%A9%20%26%20Cia")
        assertEquals("100.1.2.3", p.host)
        assertEquals("Café & Cia", p.mac)
    }

    @Test fun missingPortUsesDefaultAndMissingMacUsesPlaceholder() {
        val p = PairingLink.parse("orb://parear?host=1.2.3.4&token=$token")
        assertEquals(47821, p.port)
        assertEquals("Mac", p.mac)
    }

    @Test fun acceptsBracketedIpv6() {
        assertEquals("fd7a:115c:a1e0::1", PairingLink.parse("orb://parear?host=%5Bfd7a:115c:a1e0::1%5D&token=$token").host)
    }

    @Test fun rejectsInvalidPorts() {
        for (port in listOf("0", "65536", "-1", "abc", "", "47821.5")) {
            assertThrows("port=$port", PairingException::class.java) {
                PairingLink.parse("orb://parear?host=1.2.3.4&port=$port&token=$token")
            }
        }
    }

    @Test fun acceptsPortLimits() {
        assertEquals(65535, PairingLink.parse("orb://parear?host=h&port=65535&token=$token").port)
    }

    @Test fun rejectsBadTokens() {
        for (t in listOf("", "short", "A".repeat(42), "A".repeat(44), "A".repeat(42) + "=", "A".repeat(42) + "+")) {
            assertThrows("token=$t", PairingException::class.java) { PairingLink.parse("orb://parear?host=h&token=$t") }
        }
        assertThrows(PairingException::class.java) { PairingLink.parse("orb://parear?host=h") }
    }

    @Test fun rejectsEmptyOrMalformedHost() {
        for (h in listOf("", "%20", "a b", "a/b", "x@y")) {
            assertThrows("host=$h", PairingException::class.java) { PairingLink.parse("orb://parear?host=$h&token=$token") }
        }
        assertThrows(PairingException::class.java) { PairingLink.parse("orb://parear?token=$token") }
    }

    @Test fun rejectsWrongSchemeOrHost() {
        for (l in listOf("http://parear?host=h&token=$token", "orb://outro?host=h&token=$token", "", "host=h&token=$token", "orb://parear.evil.com?host=h&token=$token")) {
            assertThrows(l, PairingException::class.java) { PairingLink.parse(l) }
        }
    }

    @Test fun invalidPercentEncodingIsIgnoredNotCrashing() {
        assertThrows(PairingException::class.java) { PairingLink.parse("orb://parear?host=%ZZ&token=$token") }
    }

    @Test fun firstDuplicateWinsAndToStringHidesToken() {
        val p = PairingLink.parse("orb://parear?host=1.1.1.1&host=2.2.2.2&token=$token")
        assertEquals("1.1.1.1", p.host)
        assertFalse(p.toString().contains(token))
    }
}
