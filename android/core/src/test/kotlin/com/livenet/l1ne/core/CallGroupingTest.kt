package com.livenet.l1ne.core

import kotlin.test.Test
import kotlin.test.assertEquals

class CallGroupingTest {
    private data class C(val peer: String, val kind: Int, val t: Long)
    private val min = 60_000L
    private fun g(vararg c: C) = groupCalls(c.toList(), { it.peer }, { it.kind }, { it.t }).map { it.size }

    @Test fun severalOutgoingCallsToTheSamePersonAreOneLine() = assertEquals(listOf(3), g(C("1001", 0, 100 * min), C("1001", 0, 90 * min), C("1001", 0, 80 * min)))
    @Test fun anIncomingCallFromThemIsSeparate() = assertEquals(listOf(1, 1, 1), g(C("1001", 0, 100 * min), C("1001", 1, 95 * min), C("1001", 0, 90 * min)))
    @Test fun callsMoreThanAnHourApartAreSeparate() = assertEquals(listOf(1, 1), g(C("1001", 0, 200 * min), C("1001", 0, 100 * min)))
    @Test fun eachCallIsComparedWithTheOneBeforeItSoALongRunStaysTogether() = assertEquals(listOf(3), g(C("1001", 0, 150 * min), C("1001", 0, 100 * min), C("1001", 0, 50 * min)))
    @Test fun someoneElseInBetweenSplitsTheGroup() = assertEquals(listOf(1, 1, 1), g(C("1001", 0, 100 * min), C("1002", 0, 99 * min), C("1001", 0, 98 * min)))
    @Test fun theSameNumberWrittenTwoWaysIsTheSamePerson() = assertEquals(listOf(2), g(C("6517604266@pbx", 0, 10 * min), C("+1 (651) 760-4266", 0, 5 * min)))
    @Test fun missedCallsGroupTooButNotWithAnsweredOnes() = assertEquals(listOf(2, 1), g(C("1001", 2, 30 * min), C("1001", 2, 20 * min), C("1001", 1, 10 * min)))
}
