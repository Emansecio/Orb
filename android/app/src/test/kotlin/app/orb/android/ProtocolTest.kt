package app.orb.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
    @Test fun decodesBotsIgnoringUnknownFieldsAndDefaultingMissingOnes() {
        val f = Protocol.parse(
            """{"type":"bots","future":1,"bots":[
              {"id":"a","name":"Atlas","role":"Assistente","avatar":"9f2c","color":"#5B5BF0","working":true,"needsYou":false,
               "status":"Lendo","unread":2,"last":{"text":"Pronto","date":1762700000000},"extra":{"x":1}},
              {"id":"b","name":"Lia"}]}""",
        ) as Frame.Bots
        assertEquals(2, f.bots.size)
        val a = f.bots[0]
        assertTrue(a.working); assertEquals(2, a.unread); assertEquals(1762700000000, a.last?.date)
        val b = f.bots[1]
        assertNull(b.status); assertNull(b.last); assertNull(b.avatar); assertFalse(b.needsYou); assertEquals(0, b.unread)
    }

    @Test fun nullOptionalsAreAccepted() {
        val f = Protocol.parse("""{"type":"bots","bots":[{"id":"a","name":"A","status":null,"last":null,"avatar":null}]}""") as Frame.Bots
        assertNull(f.bots[0].last)
    }

    @Test fun decodesEveryItemKind() {
        val json = """{"type":"chat","bot":"a","working":true,"status":"x","items":[
          {"id":"1","date":1,"kind":"user","text":"oi"},
          {"id":"2","date":2,"kind":"bot","text":"olá","streaming":true},
          {"id":"3","date":3,"kind":"tool","text":"Rodou ls","tool":{"kind":"shell","title":"ls","detail":"ls -la","state":"running"}},
          {"id":"4","date":4,"kind":"approval","text":"t","approval":{"kind":"permission","title":"Rodando","command":"brew upgrade",
             "reason":"r","decision":null,"dangerous":true,"canAlways":true,"count":2,"question":null}},
          {"id":"5","date":5,"kind":"approval","text":"q","approval":{"kind":"question","title":"Qual?","decision":"once",
             "question":{"text":"Qual?","options":["a","b"],"multiple":true}}},
          {"id":"6","date":6,"kind":"notice","text":"aviso"},
          {"id":"7","date":7,"kind":"event","text":"evento"},
          {"id":"8","date":8,"kind":"orb","text":"de Lia"}]}"""
        val f = Protocol.parse(json) as Frame.Chat
        assertEquals(listOf("user", "bot", "tool", "approval", "approval", "notice", "event", "orb"), f.items.map { it.kind })
        assertTrue(f.working); assertEquals("x", f.status)
        assertTrue(f.items[1].streaming)
        assertEquals("running", f.items[2].tool?.state)
        val perm = f.items[3].approval!!
        assertTrue(perm.dangerous && perm.canAlways); assertNull(perm.decision); assertEquals(2, perm.count)
        val q = f.items[4].approval!!
        assertEquals(listOf("a", "b"), q.question?.options); assertTrue(q.question!!.multiple); assertEquals("once", q.decision)
    }

    @Test fun oneBrokenItemDoesNotDropTheRest() {
        val f = Protocol.parse("""{"type":"chat","bot":"a","items":[{"nope":1},{"id":"1","kind":"user","text":"oi"}]}""") as Frame.Chat
        assertEquals(1, f.items.size)
        assertFalse(f.working)
    }

    @Test fun decodesOtherFrames() {
        assertEquals(Frame.Welcome("Mac", 1), Protocol.parse("""{"type":"welcome","mac":"Mac","protocol":1}"""))
        assertEquals(Frame.Stream("a", "i", "texto"), Protocol.parse("""{"type":"stream","bot":"a","item":"i","text":"texto"}"""))
        assertEquals(Frame.Sent("r", false, false, "cheio"), Protocol.parse("""{"type":"sent","ref":"r","ok":false,"note":"cheio"}"""))
        assertEquals(Frame.Sent("r", true, true, null), Protocol.parse("""{"type":"sent","ref":"r","ok":true,"queued":true}"""))
        assertEquals(Frame.AvatarImage("a", "h", "AAAA"), Protocol.parse("""{"type":"avatar","bot":"a","hash":"h","png":"AAAA"}"""))
        assertEquals(Frame.Pong, Protocol.parse("""{"type":"pong"}"""))
        assertEquals(Frame.Error("unauthorized", "x"), Protocol.parse("""{"type":"error","code":"unauthorized","message":"x"}"""))
    }

    @Test fun garbageAndUnknownTypesAreNull() {
        assertNull(Protocol.parse("not json"))
        assertNull(Protocol.parse("[]"))
        assertNull(Protocol.parse("""{"type":"mystery"}"""))
        assertNull(Protocol.parse("""{"type":"chat"}"""))
        assertNull(Protocol.parse("""{"nothing":true}"""))
    }

    @Test fun outgoingFramesFollowTheContract() {
        val hello = Protocol.json.parseToJsonElement(Protocol.hello("tok", "Pixel")).toString()
        assertTrue(hello.contains("\"type\":\"hello\"") && hello.contains("\"token\":\"tok\"") && hello.contains("\"device\":\"Pixel\"") && hello.contains("\"protocol\":1"))
        val d = Protocol.decide("b", "i", "deny", note = "faça outra coisa")
        assertTrue(d.contains("\"approval\":\"i\"") && d.contains("\"note\":\"faça outra coisa\"") && !d.contains("reply"))
        assertTrue(Protocol.decide("b", "i", "once", reply = "A").contains("\"reply\":\"A\""))
        assertNotNull(Protocol.send("b", "oi", "ref"))
        assertEquals("""{"type":"close"}""", Protocol.close())
    }
}
