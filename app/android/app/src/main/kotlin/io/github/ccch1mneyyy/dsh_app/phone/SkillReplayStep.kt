package io.github.ccch1mneyyy.dsh_app.phone

import io.github.ccch1mneyyy.dsh_app.phone.skills.PhoneSkillReplaySelections
import io.github.ccch1mneyyy.dsh_app.phone.skills.PhoneSkillRoute

/** Native typed relation and current user-selected installation; never a tool argument object. */
class SkillReplayStep internal constructor(internal val app: PhoneSkillReplaySelections.App,
    internal val relation: PhoneSkillRoute.Step)
enum class SkillReplayPost { UNKNOWN, DIFFERENT, SATISFIED }
interface SkillReplayPlan : AutoCloseable {
    val before: ScreenSnapshot
    val target: TargetInfo?
    val alreadySatisfied: Boolean
    val attempted: Boolean
    val post: SkillReplayPost
    fun perform(allowed: () -> Boolean): ActionResult
    override fun close()
}
