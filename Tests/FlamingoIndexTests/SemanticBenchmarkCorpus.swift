import Foundation
import FlamingoCore
@testable import FlamingoIndex

/// A bilingual synthetic vault for measuring semantic search. Each target document comes
/// with queries that paraphrase it, mostly without sharing its words, in English, Chinese
/// and mixed. Generated distractors add scale and lexical noise. Deterministic.
enum SemanticBenchmarkCorpus {
    struct Doc {
        var path: String
        var text: String
        var queries: [String]
        var comments: [String] = []
    }

    static let docs: [Doc] = [
        Doc(path: "home/water-heater-maintenance.md", text: """
            # Water heater maintenance

            Flush the tank every spring: turn off the gas, attach a hose to the drain valve and run it until the water comes out clear. Sediment builds up fast with our hard water.
            The sacrificial anode rod was replaced in May 2024; check it again in 2027.
            If the pilot light keeps going out, clean the thermocouple before calling anyone.
            Temperature dial stays at 50 °C so nobody gets scalded in the shower.
            """, queries: ["how do I look after the boiler that heats our showers", "热水器怎么保养"]),
        Doc(path: "pets/biscuit-vet-records.md", text: """
            # Biscuit — vet records

            Golden retriever, born 14 June 2023.
            Rabies booster given 2 March 2025, next one due March 2028.
            DHPP booster due every three years. Heartworm tablet on the first of every month.
            Weight at last visit: 31 kg. Dr. Alvarez says cut the treats.
            """, queries: ["when is the puppy due for its next jabs", "狗狗下次打疫苗是什么时候"]),
        Doc(path: "travel/japan-visa-checklist.md", text: """
            # Japan visa checklist

            For the consulate appointment bring: passport valid for six more months, two 45×35 mm photos with a white background, three months of bank statements, the flight booking and a day-by-day itinerary, and the employer letter stating leave dates.
            Processing takes five working days. Pick up in person.
            """, queries: ["paperwork needed for the trip to Tokyo", "去日本签证要准备什么材料"]),
        Doc(path: "finance/2025-tax-deductions.md", text: """
            # 2025 tax deductions

            Home office: the spare room is 11 m² of a 92 m² flat, so 12% of rent and utilities.
            Keep receipts for the monitor, desk chair and the share of the internet bill.
            Charitable donations: Red Cross and the food bank, receipts in the blue folder.
            Accountant needs everything by 31 January.
            """, queries: ["what can I write off for working from home", "在家办公能抵多少税"]),
        Doc(path: "work/incident-2026-03-postmortem.md", text: """
            # Postmortem: checkout outage, 18 March 2026

            Duration 47 minutes. The primary database ran out of connections after a deploy doubled the worker count without raising the pool limit. Requests queued, then timed out, and customers saw error pages at checkout.
            Action items: alert on pool saturation, cap workers per host, add a load test to the release checklist.
            """, queries: ["why did the site go down in March", "三月份网站宕机的原因"]),
        Doc(path: "work/onboarding-new-engineers.md", text: """
            # Onboarding new engineers

            Day one: laptop, accounts for GitHub, Slack and the VPN, and lunch with the team.
            Every new hire gets a buddy for the first month.
            First week: ship a small bug fix to production, read the architecture overview, shadow an on-call shift.
            By day thirty they should own a small feature end to end.
            """, queries: ["first week plan for people who just joined", "新员工第一周做什么"]),
        Doc(path: "recipes/sourdough.md", text: """
            # Sourdough

            Feed the starter twice a day for three days before baking; it should double in four hours.
            500 g flour, 375 g water (75% hydration), 100 g levain, 10 g salt.
            Bulk ferment about five hours with four sets of stretch and folds, shape, then retard in the fridge overnight.
            Bake in a preheated Dutch oven at 250 °C, lid on for 20 minutes, lid off for 25.
            """, queries: ["how to bake bread with wild yeast", "酸面包的做法"]),
        Doc(path: "health/physio-knee-rehab.md", text: """
            # Physio: knee rehab after ACL reconstruction

            Weeks 1–2: quad sets, straight leg raises, heel slides, three sets of ten, twice a day. Ice for 15 minutes afterwards.
            Weeks 3–6: stationary bike with no resistance, mini squats to 45 degrees, balance on one foot.
            No running until the surgeon clears it at the twelve-week check.
            """, queries: ["exercises for my leg after the ligament operation"]),
        Doc(path: "garden/tomato-blight.md", text: """
            # Tomato blight

            Lower leaves turned yellow with brown concentric spots, spreading upwards after the wet week. Early blight, most likely.
            Remove affected foliage and bin it, don't compost. Water at the base in the morning, mulch to stop soil splashing onto the leaves.
            Copper spray every 7–10 days. Rotate the bed next year.
            """, queries: ["my vegetable plants have spotted dying leaves", "番茄叶子发黄有斑点怎么办"]),
        Doc(path: "car/ev-charging-costs.md", text: """
            # EV charging costs

            Wallbox 7 kW in the garage, scheduled for the off-peak window 00:30–04:30 at 9p per kWh.
            The car averages 16 kWh per 100 km, so roughly 1.4p per km at home versus 8p per km at motorway rapid chargers.
            Annual mileage 12,000 km.
            """, queries: ["how much does it cost to power the electric car", "电动车充电一公里多少钱"]),
        Doc(path: "work/q2-okrs.md", text: """
            # Q2 OKRs

            Objective 1: Reduce churn. KR: monthly churn below 3%; KR: onboarding completion above 70%.
            Objective 2: Launch the public API v2. KR: ten design partners live; KR: p95 latency under 200 ms.
            Objective 3: Hire two senior engineers.
            """, queries: ["goals for the second quarter", "第二季度的目标"]),
        Doc(path: "kids/school-pickup-rota.md", text: """
            # School pickup rota

            Monday — Alice's mum. Tuesday — Ben's dad. Wednesday — us. Thursday — Chloe's grandparents. Friday — us, then swimming at 4:30.
            Gate closes at 3:15. Text the group if you are running late.
            """, queries: ["who collects the children on which day", "谁哪天去学校接孩子"]),
        Doc(path: "home/mortgage-refinance-comparison.md", text: """
            # Mortgage refinance comparison

            Current lender: variable 5.3%, no exit fee after March.
            Offer A: 4.1% fixed for five years, £999 arrangement fee.
            Offer B: tracker at base + 0.6%, no fees, can overpay 20% a year.
            Broker thinks A wins unless rates fall more than a point.
            """, queries: ["should we switch our home loan to another bank", "房贷要不要转贷"]),
        Doc(path: "work/api-rate-limiting-design.md", text: """
            # API rate limiting design

            Token bucket per API key: 100 requests a minute, bursts up to 20. Counters live in Redis with a 60-second TTL.
            Over the limit the gateway answers 429 with a Retry-After header. Internal services are exempt.
            Open question: per-tenant limits for enterprise plans.
            """, queries: ["throttling how often clients can call the service"]),
        Doc(path: "personal/best-man-speech.md", text: """
            # Best man speech — draft

            Thank the parents and the caterers first. The camping story, but not the part with the police.
            How he met Sara: the wrong train to Edinburgh. End with raising a glass to the couple.
            Keep it under five minutes.
            """, queries: ["toast for my brother's wedding", "婚礼上的致辞稿"]),
        Doc(path: "research/sleep-notes.md", text: """
            # Sleep notes

            Caffeine has a half-life of about five hours, so the 3 pm coffee is still half there at 8 pm.
            Screens: dim and warm after 9. Keep the bedroom at 18 °C.
            Same wake-up time every day matters more than bedtime. Insomnia got better after two weeks of this.
            """, queries: ["why can't I fall asleep at night", "晚上睡不着怎么办"]),
        Doc(path: "work/vendor-security-questionnaire.md", text: """
            # Vendor security questionnaire — answers

            SOC 2 Type II report available under NDA. Data encrypted at rest with AES-256 and in transit with TLS 1.2+.
            Annual penetration test by an external firm; last one in April, no critical findings.
            Customer data stays in the EU region. Access reviews quarterly.
            """, queries: ["compliance form about how we protect customer information", "供应商安全问卷"]),
        Doc(path: "home/moving-checklist.md", text: """
            # Moving checklist

            Four weeks out: book the van, start packing the loft, order boxes.
            Two weeks: redirect post, transfer broadband and electricity, tell the council.
            Moving day: meter readings, photos of the empty rooms, keys to the agent.
            """, queries: ["tasks before relocating to the new flat"]),
        Doc(path: "finance/crypto-holdings.txt", text: """
            Crypto holdings, updated 1 Oct 2026
            BTC 0.42 on the hardware wallet (seed phrase in the safe)
            ETH 3.1, staked
            Sold the SOL in August. Never more than 5% of net worth in this.
            """, queries: ["digital currency investments", "比特币持仓"]),
        Doc(path: "work/hiring-rubric-backend.md", text: """
            # Backend interview rubric

            Score each area 1–4: system design, coding, debugging, communication.
            A strong hire needs at least two 4s and no 1s. Write evidence, not impressions.
            Debrief within 24 hours; the hiring manager breaks ties.
            """, queries: ["how we grade candidates after interviews", "面试评分标准"]),
        Doc(path: "notes/book-club-dune.md", text: """
            # Book club: Dune

            Everyone liked the ecology more than the politics. The spice as oil was the obvious reading; Priya argued it is really about water.
            Paul as a warning about saviours, not a hero. Next month: The Left Hand of Darkness.
            """, queries: ["discussion of the desert planet novel"]),
        Doc(path: "work/release-notes-3.2.md", text: """
            # Release notes 3.2

            New: dark mode, offline sync for notes, keyboard shortcuts for search.
            Fixed: crash when importing large PDFs, wrong time zone in reminders.
            Removed: the legacy export to Evernote.
            """, queries: ["what changed in the latest app update", "新版本更新了什么"]),
        Doc(path: "home/solar-panel-quote.md", text: """
            # Solar panel quote

            6.6 kW system: 18 panels on the south roof, hybrid inverter, 10 kWh battery.
            Price £9,800 installed, scaffolding included. Expected generation 5,900 kWh a year; payback around seven years with export tariff.
            """, queries: ["price to put photovoltaics on the roof", "屋顶装太阳能要多少钱"]),
        Doc(path: "health/allergy-action-plan.md", text: """
            # Allergy action plan — Leo

            Severe peanut and tree nut allergy. Signs: hives, swelling of the lips, coughing, vomiting.
            Use the EpiPen in the outer thigh at the first sign of breathing trouble, then call an ambulance. A second pen after five minutes if no improvement.
            """, queries: ["what to do if my son eats something with nuts", "孩子过敏了怎么急救"]),
        Doc(path: "finance/household-budget.csv", text: """
            category,monthly,notes
            rent,1850,due on the 1st
            groceries,620,two big shops a week
            utilities,240,electric gas water
            childcare,900,nursery three days
            transport,180,train passes
            """, queries: ["monthly spending on food and rent", "每月家庭开支"]),
        Doc(path: "work/design-review-2026-09-12.md", text: """
            # Design review, 12 September

            Navigation redesign: the sidebar collapses to icons below 900 px. Contrast of the grey labels fails accessibility; darken to meet 4.5:1.
            Search moves into the top bar. Next review after the usability sessions.
            """, queries: ["feedback on the new menu layout"]),
        Doc(path: "travel/iceland-itinerary.md", text: """
            # Iceland itinerary

            Day 1–2 Reykjavík and the Golden Circle. Day 3 Vík and the black sand beach. Day 4 Jökulsárlón glacier lagoon. Day 5–6 east fjords, Day 7 Mývatn hot springs.
            Hire car with gravel insurance. Check aurora forecast every night.
            """, queries: ["road trip plan around the volcanic island", "冰岛自驾行程"]),
        Doc(path: "work/churn-analysis.md", text: """
            # Churn analysis

            Monthly churn is 4.2%, almost all of it small businesses in their first 60 days.
            Accounts that never connect a calendar cancel at three times the rate. Fix onboarding before pricing.
            """, queries: ["why are customers cancelling their subscriptions", "用户为什么流失"]),
        Doc(path: "home/flood-insurance-claim.md", text: """
            # Insurance claim — basement flood

            Claim number HX-55821. A burst pipe flooded the basement on 3 February.
            Adjuster visited on the 9th; dehumidifiers ran for two weeks. Excess £250. Waiting on the quote for new flooring.
            """, queries: ["water damage claim with the insurer", "地下室漏水保险理赔"]),
        Doc(path: "生活/装修预算.md", text: """
            # 装修预算

            厨房橱柜 3.2 万，地板 1.8 万，水电改造 2.5 万，卫生间重做 2 万。
            总预算控制在 12 万以内，预留 10% 应急。施工队下周一进场。
            """, queries: ["房子翻新要花多少钱", "renovation budget for the apartment"]),
        Doc(path: "工作/季度汇报-2026Q3.md", text: """
            # 2026 年第三季度汇报

            营收 412 万元，环比增长 38%。付费用户留存率提升到 91%。
            下季度重点：海外市场试点，企业版定价调整，招聘两名后端工程师。
            """, queries: ["三季度业绩怎么样", "third quarter results summary"]),
        Doc(path: "健康/体检报告解读.md", text: """
            # 体检报告解读

            总胆固醇 6.1，低密度脂蛋白偏高；尿酸 460，略高。肝功能正常。
            医生建议少吃红肉和动物内脏，每周运动三次，三个月后复查血脂。
            """, queries: ["年度身体检查结果", "annual checkup results and cholesterol"]),
        Doc(path: "旅行/成都美食攻略.md", text: """
            # 成都美食攻略

            火锅推荐小龙坎和蜀九香，串串去玉林路。宽窄巷子人多，吃个钟水饺就走。
            早餐一定要试担担面和红油抄手。辣度点微辣就够了。
            """, queries: ["四川有什么好吃的", "food guide for Chengdu"]),
        Doc(path: "孩子/小学报名材料.md", text: """
            # 小学报名材料

            户口本原件及复印件、房产证、出生证明、预防接种证、父母身份证。
            网上报名截止 5 月 20 日，6 月初现场审核。
            """, queries: ["孩子上学需要准备哪些证件", "documents to enrol my kid in primary school"]),
        Doc(path: "工作/新人入职指南.md", text: """
            # 新人入职指南

            第一天：领电脑，开通邮箱、企业微信和 VPN 账号。每位新同事配一名导师，带一个月。
            第一周：熟悉代码库，修一个小 bug 上线，旁听一次值班。
            """, queries: ["新同事入职第一周安排", "first days checklist for a new colleague"]),
        Doc(path: "理财/基金定投计划.md", text: """
            # 基金定投计划

            每月 15 号定投沪深 300 指数基金 3000 元，纳斯达克 100 指数 2000 元。
            年化收益超过 15% 分批止盈，回撤超过 20% 加倍投入。
            """, queries: ["每个月固定买基金的方案", "monthly index fund investing plan"]),
        Doc(path: "家居/空调清洗.md", text: """
            # 空调清洗

            滤网每两周拆下来用清水冲洗，晾干再装。蒸发器用专用清洗剂喷，等十分钟。
            如果制冷变差，可能是缺氟，要找售后加制冷剂。异味多半是滤网发霉。
            """, queries: ["空调有怪味怎么办", "air conditioner smells musty"]),
        Doc(path: "工作/接口限流方案.md", text: """
            # 接口限流方案

            采用令牌桶算法，每个密钥每分钟 100 次请求，突发上限 20。计数存在 Redis。
            超限返回 429 并带上 Retry-After。内部服务不限流。
            """, queries: ["怎么限制客户端调用频率"]),
        Doc(path: "读书/三体读后感.md", text: """
            # 《三体》读后感

            黑暗森林法则是全书最震撼的设定：宇宙中每个文明都是带枪的猎人。
            叶文洁的选择让人难过。第二部比第一部好看，罗辑的面壁计划很精彩。
            """, queries: ["那本外星文明科幻小说的感想", "thoughts on the alien civilisation sci-fi trilogy"]),
        Doc(path: "生活/搬家清单.md", text: """
            # 搬家清单

            提前一个月订搬家公司，买纸箱。提前两周办宽带迁移，改快递地址。
            搬家当天抄水电表，拍空房照片，把钥匙交给房东。
            """, queries: ["搬去新家之前要做的事"]),
        Doc(path: "健康/膝盖康复训练.md", text: """
            # 膝盖康复训练

            术后前两周：股四头肌收缩、直腿抬高、足跟滑动，每组十次，每天两次，练完冰敷。
            三到六周：无阻力单车，小幅度深蹲，单脚站立练平衡。十二周复查前不要跑步。
            """, queries: ["韧带手术后腿部怎么锻炼"]),
        Doc(path: "工作/竞品分析-笔记软件.md", text: """
            # 竞品分析：笔记软件

            Notion 协作强但离线差；Obsidian 本地优先、插件多，但上手难；印象笔记老用户多，增长停滞。
            我们的机会：本地文件 + 全文检索 + 双向链接。
            """, queries: ["笔记应用横向对比", "comparison of competing note-taking apps"]),
        Doc(path: "家庭/春节安排.md", text: """
            # 春节安排

            腊月二十八开车回老家，大年三十在奶奶家吃年夜饭。红包预算 6000 元。
            初三去外婆家，初六返程，避开高峰。
            """, queries: ["过年回家的计划", "plans for chinese new year with family"]),
        Doc(path: "宠物/猫咪绝育.md", text: """
            # 猫咪绝育

            十月十日在宠物医院做绝育手术，术前八小时禁食。术后戴伊丽莎白圈十天，防止舔伤口。
            七天后复查拆线。这段时间不要洗澡。
            """, queries: ["给猫做完手术怎么照顾", "caring for the cat after spaying"]),
        Doc(path: "work/product-roadmap-2027.md", text: """
            # Product roadmap 2027

            Q1: 多语言支持 (i18n) and the new onboarding flow.
            Q2: offline mode 离线模式, conflict resolution for shared notes.
            Q3: 企业版 SSO and audit logs. Q4: mobile widgets.
            """, queries: ["feature plan for next year", "明年的产品规划"]),
        Doc(path: "meetings/standup-notes-mixed.md", text: """
            # Standup notes

            Kai: 修复登录 bug, the session cookie expired too early on Safari. Fixed, in review as PR #482.
            Mei: 设计稿还没好, blocked on icons. Tom: migrating the billing cron.
            """, queries: ["status of the sign-in problem", "登录问题修好了吗"]),
        Doc(path: "travel/shanghai-business-trip.md", text: """
            # Shanghai business trip

            Flight MU588 on Monday, hotel at 静安香格里拉. Client meeting with 王总 on Tuesday at 10:00 about the renewal.
            Wednesday factory visit in Kunshan, back Thursday.
            """, queries: ["visiting clients in Shanghai itinerary", "去上海出差的安排"]),
        Doc(path: "finance/expense-report-2026-09.md", text: """
            # Expense report, September 2026

            打车 ¥86, dinner with the client ¥420, hotel two nights ¥1,380, train to Hangzhou ¥146.
            Total ¥2,032. Receipts scanned into the shared drive.
            """, queries: ["reimbursement for September costs", "九月份报销明细"]),
        Doc(path: "research/interview-lena-notes.md", text: """
            # Customer interview — Lena, studio owner

            Runs a four-person architecture studio. Uses three different apps for notes and hates exporting between them.
            Would pay for one place that finds old drawings by what is in them.
            """, queries: ["what did Lena say about the deadline"], comments: [
                "Lena said the September deadline is impossible unless we cut the export feature.",
            ]),
        Doc(path: "work/launch-retro.md", text: """
            # Launch retrospective

            What went well: support was ready, the landing page converted at 6%.
            What did not: the email went out twice, and the status page was not updated during the outage.
            """, queries: ["what did Omar think about the press coverage"], comments: [
                "Omar thinks the press coverage was thin because we pitched only two journalists a day before launch.",
            ]),
    ]

    /// Queries with more than one relevant file.
    static let shared: [(query: String, relevant: [String])] = [
        ("first week checklist for new staff", ["work/onboarding-new-engineers.md", "工作/新人入职指南.md"]),
        ("rate limit with token bucket and 429", ["work/api-rate-limiting-design.md", "工作/接口限流方案.md"]),
        ("knee exercises after surgery", ["health/physio-knee-rehab.md", "健康/膝盖康复训练.md"]),
        ("moving house to do list", ["home/moving-checklist.md", "生活/搬家清单.md"]),
    ]

    /// Exact-term queries where keyword search should keep winning.
    static let exact: [(query: String, relevant: [String])] = [
        ("Jökulsárlón", ["travel/iceland-itinerary.md"]),
        ("PR #482", ["meetings/standup-notes-mixed.md"]),
        ("MU588", ["travel/shanghai-business-trip.md"]),
        ("HX-55821", ["home/flood-insurance-claim.md"]),
        ("sourdough", ["recipes/sourdough.md"]),
        ("令牌桶", ["工作/接口限流方案.md"]),
    ]

    static var cases: [SemanticEval.Case] {
        var out: [SemanticEval.Case] = []
        for doc in docs {
            for q in doc.queries {
                let kind: String
                if q.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
                    kind = doc.text.unicodeScalars.filter({ (0x4E00...0x9FFF).contains($0.value) }).count > 20 ? "zh" : "cross"
                } else {
                    kind = doc.text.unicodeScalars.filter({ (0x4E00...0x9FFF).contains($0.value) }).count > 20 ? "cross" : "en"
                }
                out.append(.init(query: q, relevant: [doc.path], kind: kind))
            }
        }
        out += shared.map { .init(query: $0.query, relevant: $0.relevant, kind: "shared") }
        out += exact.map { .init(query: $0.query, relevant: $0.relevant, kind: "exact") }
        return out
    }

    /// Writes the targets, their comments, and `distractors` generated files.
    static func write(to root: URL, distractors: Int = 1200) throws {
        let fm = FileManager.default
        let vault = Vault(root: root)
        let sidecars = SidecarStore(vault: vault)
        for doc in docs {
            let url = root.appendingPathComponent(doc.path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try doc.text.write(to: url, atomically: true, encoding: .utf8)
            for c in doc.comments { try sidecars.append(Comment(text: c), to: FileRef(relativePath: doc.path)) }
        }
        var rng = SplitMix(seed: 42)
        for i in 0..<distractors {
            let (path, text) = distractor(i, &rng)
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            return z ^ (z >> 31)
        }
        mutating func pick<T>(_ a: [T]) -> T { a[Int(next() % UInt64(a.count))] }
        mutating func int(_ r: ClosedRange<Int>) -> Int { r.lowerBound + Int(next() % UInt64(r.count)) }
    }

    static let projects = ["Falcon", "Juniper", "Atlas", "Nimbus", "Orchid", "Quartz", "Harbor", "Ember", "Willow", "Cobalt"]
    static let people = ["Ana", "Ravi", "Jonas", "Sofia", "Wei", "Hana", "Marco", "Ines", "Tariq", "Elif"]
    static let statusLines = [
        "Milestone two slipped by a week because the vendor delivered the parts late.",
        "Integration tests are green on the staging cluster.",
        "Waiting for legal to review the contract amendment.",
        "Design handed over the final mockups for the dashboard.",
        "We agreed to move the demo to Thursday.",
        "Load testing showed the queue handles twice the expected volume.",
        "Budget for the quarter is on track, slightly under on travel.",
        "Two open bugs block the beta: the export button and the date picker.",
        "The data migration finished overnight without errors.",
        "Marketing wants a short video for the announcement.",
        "Hiring: one offer accepted, one candidate in the final round.",
        "The office move is scheduled for the end of next month.",
    ]
    static let vendors = ["Northwind Supplies", "Acme Office", "Blue River Printing", "Contoso Catering", "Fabrikam Hardware", "Litware Cloud"]
    static let items = ["printer toner", "standing desks", "conference catering", "cloud hosting", "laptop chargers", "brochure printing", "whiteboard markers", "network switches"]
    static let history = [
        "The Hanseatic League controlled trade in the Baltic for three centuries.",
        "The printing press spread across Europe within fifty years of its invention.",
        "Roman aqueducts carried water over long distances using only gravity.",
        "The Silk Road connected Chang'an with the Mediterranean world.",
        "Medieval guilds set prices and trained apprentices in every trade.",
        "The transatlantic telegraph cable was completed in 1866.",
        "Venice built its fleet in the Arsenal, an early assembly line.",
        "The Great Fire of London destroyed most of the medieval city in 1666.",
    ]
    static let zhStatus = [
        "本周完成了数据迁移，没有发现问题。", "设计稿已经交付，等待评审。", "测试环境部署成功，接口联调中。",
        "供应商交货延迟一周，影响第二个里程碑。", "市场部希望下周发布宣传视频。", "预算执行正常，差旅费用略有结余。",
        "两个缺陷阻塞了内测版本。", "办公室搬迁定在下个月底。",
    ]

    static func distractor(_ i: Int, _ rng: inout SplitMix) -> (String, String) {
        switch i % 5 {
        case 0:
            let p = rng.pick(projects)
            let lines = (0..<rng.int(3...6)).map { _ in "- " + rng.pick(statusLines) }
            return ("archive/status/\(p.lowercased())-\(i).md", "# \(p) status, week \(rng.int(1...52))\n\nOwner: \(rng.pick(people))\n\n" + lines.joined(separator: "\n"))
        case 1:
            let v = rng.pick(vendors), item = rng.pick(items), qty = rng.int(1...40), unit = rng.int(5...900)
            return ("archive/invoices/invoice-\(10000 + i).txt", "Invoice \(10000 + i)\nVendor: \(v)\nItem: \(item)\nQuantity: \(qty)\nUnit price: \(unit).00\nTotal: \(qty * unit).00\nPayment terms: net 30\n")
        case 2:
            let lines = (0..<rng.int(4...10)).map { _ in
                "2026-0\(rng.int(1...9))-1\(rng.int(0...9)) \(rng.int(10...23)):\(rng.int(10...59)):\(rng.int(10...59)) INFO worker-\(rng.int(1...8)) processed batch \(rng.int(1000...9999)) in \(rng.int(20...900))ms"
            }
            return ("archive/logs/worker-\(i).log", lines.joined(separator: "\n"))
        case 3:
            let lines = (0..<rng.int(2...4)).map { _ in rng.pick(history) }
            return ("archive/reading/history-\(i).md", "# Reading notes \(i)\n\n" + lines.joined(separator: " "))
        default:
            let p = rng.pick(projects)
            let lines = (0..<rng.int(2...5)).map { _ in "- " + rng.pick(zhStatus) }
            return ("archive/周报/\(p)-\(i).md", "# \(p) 项目周报 第\(rng.int(1...52))周\n\n负责人：\(rng.pick(people))\n\n" + lines.joined(separator: "\n"))
        }
    }
}
