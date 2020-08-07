
import Foundation
import UIKit
import Contentful

class CourseViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, CustomNavigable {

    init(course: Course?, services: ApplicationServices) {
        self.course = course
        self.services = services
        super.init(nibName: nil, bundle: nil)

        self.hidesBottomBarWhenPushed = false
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var course: Course? {
        didSet {
            assert(course != nil)
            DispatchQueue.main.async { [weak self] in
                if let strongSelf = self, strongSelf.course != nil {
                    strongSelf.tableView?.delegate = self
                    strongSelf.resolveStateOnLessons()
                }
            }
        }
    }
    var services: ApplicationServices

    var tableView: UITableView! 

    /**
     * The lessons collection view controller for a course that is currenlty pushed onto the navigation stack.
     * This property is declared as weak so that when the navigaton controller pops the course view controller
     * it will not be retained here.
     */
    weak var lessonsViewController: LessonsCollectionViewController?

    // We must retain the data source.
    var tableViewDataSource: UITableViewDataSource? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.tableView?.dataSource = self!.tableViewDataSource
                self?.tableView?.reloadData()
            }
        }
    }

    let courseOverviewCellFactory = TableViewCellFactory<CourseOverviewTableViewCell>()
    let lessonCellFactory = TableViewCellFactory<LessonTableViewCell>()

    // MARK: CustomNavigable
    
    var hasCustomToolbar: Bool {
        return false
    }

    var prefersLargeTitles: Bool {
        return false
    }


    // Contentful query.
    func query(slug: String) -> QueryOn<Course> {
        let localeCode = services.contentful.currentLocaleCode
        let query = QueryOn<Course>.where(field: .slug, .equals(slug)).include(3).localizeResults(withLocaleCode: localeCode)
        return query
    }

    // Request.
    var courseRequest: URLSessionTask?

    func updateWithNewState() {
        guard let course = course else { return }
        fetchCourseWithSlug(course.slug)
    }

    // This method is called by Router when deeplinking into a course and/or lesson.
    public func fetchCourseWithSlug(_ slug: String, showLessonWithSlug lessonSlug: String? = nil) {

        // When coming from a deeplink, viewDidLoad, isn't called before the LessonsCollectionViewController is pushed.
        // Therefore we don't have state observations set up properly; we should those observations here.
        removeStateObservations()
        addStateObservations()

        tableViewDataSource = LoadingTableViewDataSource()

        showLoadingStateOnLessonsCollection()
        courseRequest?.cancel()
        courseRequest = services.contentful.client.fetchArray(of: Course.self, matching: query(slug: slug)) { [weak self] result in
            DispatchQueue.main.async {
                guard let strongSelf = self else { return }
                strongSelf.courseRequest = nil
                switch result {
                case .success(let arrayResponse):
                    if arrayResponse.items.count == 0 {
                        let error: NoContentError
                        if let lessonSlug = lessonSlug {
                            error = NoContentError.noLessons(contentfulService: strongSelf.services.contentful,
                                                             route: "courses/\(slug)/lessons/\(lessonSlug)", fontSize: 14.0)
                        } else {
                            error = NoContentError.noCourse(contentfulService: strongSelf.services.contentful,
                                                            route: "courses/\(slug)", fontSize: 14.0)
                        }
                        strongSelf.showNoContentErrorAndPop(error: error)
                        return
                    }
                    strongSelf.course = arrayResponse.items.first!
                    strongSelf.tableViewDataSource = strongSelf
                    strongSelf.tableView?.delegate = strongSelf

                    guard let lessonSlug = lessonSlug ?? self?.lessonsViewController?.currentlyVisibleLesson?.slug else {
                        Analytics.shared.logViewedRoute("/courses/\(strongSelf.course!.slug)", spaceId: strongSelf.services.contentful.credentials.spaceId)
                        return
                    }
                    guard strongSelf.course!.hasLessons else {
                        // Tried to deep link into a lessons, but no lessons found.
                        let error = NoContentError.noLessons(contentfulService: strongSelf.services.contentful,
                                                             route: "courses/\(slug)/lessons/\(lessonSlug)",
                                                             fontSize: 14.0)
                        strongSelf.showNoContentErrorAndPop(error: error)
                        return
                    }
                    guard strongSelf.course!.lessons!.contains(where: { $0.slug == lessonSlug }) else {
                        // If lessons are currenlty being displayed, and the course doesn't contain the lesson we want to display
                        // just go back to the course overview.
                        strongSelf.lessonsViewController?.navigationController?.popViewController(animated: true)
                        return
                    }

                    strongSelf.lessonsViewController?.setCourse(strongSelf.course!, showLessonWithSlug: lessonSlug)

                case .failure(let error):
                    let model = ErrorTableViewCell.Model(error: error, services: strongSelf.services)
                    strongSelf.tableViewDataSource = ErrorTableViewDataSource(model: model)
                }
            }
        }
    }

    private func showNoContentErrorAndPop(error: ApplicationError) {
        DispatchQueue.main.async { [weak self] in
            guard let navigationController = self?.navigationController else { return }
            let alertController = AlertController.noContentErrorAlertController(error: error)
            navigationController.popViewController(animated: true)
            navigationController.present(alertController, animated: true, completion: nil)
        }
    }

    private func showNoContentError(_ error: ApplicationError) {
        DispatchQueue.main.async { [weak self] in
            guard let navigationController = self?.navigationController else { return }
            let alertController = AlertController.noContentErrorAlertController(error: error)
            navigationController.present(alertController, animated: true, completion: nil)
        }
    }

    public func pushLessonsCollectionViewAndShowLesson(at index: Int, animated: Bool) {
        let lessonsViewController = LessonsCollectionViewController(course: course, services: services)

        lessonsViewController.onAppear = {
            lessonsViewController.collectionView.scrollToItem(at: IndexPath(row: index, section: 0), at: .centeredHorizontally, animated: false)
        }
        navigationController?.pushViewController(lessonsViewController, animated: animated)
        self.lessonsViewController = lessonsViewController
    }

    public func resolveStateOnCourse() {
        guard let course = self.course else { return }

        services.contentful.willResolveStateIfNecessary(for: course) { [weak self] (result: Result<Course, Error>, _) in
            switch result {
            case .success(let statefulCourse):
                self?.course = statefulCourse
            case .failure:
                break
            }
        }
    }

    public func resolveStateOnLessons() {
        guard let course = self.course, let lessons = course.lessons else { return }

        for lesson in lessons {
            services.contentful.willResolveStateIfNecessary(for: lesson) { [weak self] (result: Result<Lesson, Error>, deliveryLesson: Lesson?) in
                switch result {
                case .success(var statefulPreviewLesson):
                    guard let statefulPreviewLessonModules = statefulPreviewLesson.modules,
                        let self = self,
                        let deliveryModules = deliveryLesson?.modules
                    else { return }

                    // Aggregate state on the Lesson's by looking at the states on each module in `modules: [LessonModule]?` property and update.
                    statefulPreviewLesson = self.services.contentful.inferStateFromLinkedModuleDiffs(
                        statefulRootAndModules: (statefulPreviewLesson, statefulPreviewLessonModules),
                        deliveryModules: deliveryModules
                    )

                    if let index = lessons.index(where: { $0.id == statefulPreviewLesson.id }) {
                        self.course?.lessons?[index] = statefulPreviewLesson
                        self.lessonsViewController?.updateLessonStateAtIndex(index)
                    }

                case .failure:
                    break
                }
            }
        }
    }

    func showLoadingStateOnLessonsCollection() {
        DispatchQueue.main.async { [weak self] in
            if let strongSelf = self, let lessonsViewController = strongSelf.lessonsViewController {
                lessonsViewController.showLoadingState()
            }
        }
    }

    deinit {
        print("deinit CourseViewController")
    }

    // MARK: UIViewController

    override func loadView() {
        tableView = UITableView(frame: .zero)

        tableView.registerNibFor(CourseOverviewTableViewCell.self)
        tableView.registerNibFor(LessonTableViewCell.self)
        tableView.registerNibFor(LoadingTableViewCell.self)
        tableView.registerNibFor(ErrorTableViewCell.self)

        // Enable table view cells to be sized dynamically based on inner content.
        tableView.rowHeight = UITableView.automaticDimension
        view = tableView
    }


    // State change reactions.
    var stateObservationToken: String?

    var contentfulServiceStateObservatinToken: String?

    func addStateObservations() {
        stateObservationToken = services.contentful.stateMachine.addTransitionObservation { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateWithNewState()
            }
        }

        contentfulServiceStateObservatinToken = services.contentfulStateMachine.addTransitionObservation { [weak self] _ in
            self?.removeStateObservations()
            self?.addStateObservations()
        }
    }

    func removeStateObservations() {
        if let token = stateObservationToken {
            services.contentful.stateMachine.stopObserving(token: token)
            stateObservationToken = nil
        }

        if let token = contentfulServiceStateObservatinToken {
            services.contentfulStateMachine.stopObserving(token: token)
            contentfulServiceStateObservatinToken = nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        removeStateObservations()
        addStateObservations()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if course != nil {
            tableViewDataSource = self
            tableView.delegate = self
            resolveStateOnCourse()
            Analytics.shared.logViewedRoute("/courses/\(course!.slug)", spaceId: services.contentful.credentials.spaceId)
        } else {
            tableViewDataSource = LoadingTableViewDataSource()
            tableView.delegate = nil
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // If the datasource == self, then we will have a retain cycle, so we must nullify it when off screen.
        tableViewDataSource = nil
    }

    // MARK: UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard indexPath.section == 1 else { return }
        pushLessonsCollectionViewAndShowLesson(at: indexPath.row, animated: true)
    }

    // MARK: UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch section {
        case 0:     return 1
        case 1:     return course?.lessons?.count ?? 0
        default:    return 0
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell: UITableViewCell
        switch indexPath.section {
        case 0:
            assert(indexPath.row == 0)
            guard let course = course else {
                fatalError()
            }
            let model = CourseOverviewTableViewCell.Model(contentfulService: services.contentful, course: course) { [weak self] in
                self?.pushLessonsCollectionViewAndShowLesson(at: 0, animated: true)
            }
            cell = courseOverviewCellFactory.cell(for: model, in: tableView, at: indexPath)
        case 1:
            guard let lesson = course?.lessons?[indexPath.item] else {
                fatalError()
            }
            cell = lessonCellFactory.cell(for: lesson, in: tableView, at: indexPath)
        default: fatalError()
        }
        return cell
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch section {
        case 0:     return nil
        case 1:     return "lessonsLabel".localized(contentfulService: services.contentful)
        default:    return nil
        }
    }
}
