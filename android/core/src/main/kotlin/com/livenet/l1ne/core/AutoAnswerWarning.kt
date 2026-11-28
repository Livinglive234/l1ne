package com.livenet.l1ne.core

/** What the person is told before auto answer is switched on, and what it can be abused for. The iPhone app shows the same words. */
object AutoAnswerWarning {
    const val footer = "Auto answer picks up a call by itself when the call asks for that, as intercoms and paging do. It can be abused: anyone who can call this line with the right header can make this phone answer, and with the microphone on they can listen to what is around it. You are warned in full when you turn it on."
    const val enable = "Auto answer lets a call pick up by itself, with nobody pressing Answer. It is meant for intercoms, paging and a dedicated phone.\n\n" +
        "It can be abused. Anyone who can place a call to this line and add the right header (someone on your PBX, a phone trunk, or anyone who can reach this phone on a network) can make the phone answer:\n" +
        "• With the microphone on, they can listen to the room, the car or the pocket the phone is in.\n" +
        "• With it off, they can still play sound at you, wake the phone and run the battery down.\n" +
        "• They can keep the line busy so real calls are missed.\n\n" +
        "Only turn it on for a phone nobody carries around, restrict it to the callers you list, and keep the microphone off unless you really need two-way intercom. A banner tells you whenever a call is answered this way."
    const val microphone = "With the microphone on, whoever's call is answered automatically can hear everything around this phone, and you may not notice at once.\n\n" +
        "Anyone who can ring this line with the right header can do this. Leave it off unless this phone is a dedicated intercom, and list the callers that are allowed."
}
