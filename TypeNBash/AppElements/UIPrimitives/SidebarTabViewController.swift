//
//  SidebarTabViewController.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//


public import AppKit

open class SidebarTabViewController: NSTabViewController {
    
    // MARK: Private Properties
    
    private lazy var segmentedControl = NSSegmentedControl()
    
    
    // MARK: Tab View Controller Methods
    
    open override func viewDidLoad() {
        
        super.viewDidLoad()
        
        self.tabStyle = .toolbar
        
        self.segmentedControl.segmentDistribution = .fillEqually
        self.segmentedControl.controlSize = .regular
        #if IGNORE_MISSING_API
        if #available(macOS 27, *) {
            self.segmentedControl.role = .tabs
        }
        #endif
        self.segmentedControl.target = self.tabView
        self.segmentedControl.action = #selector(NSTabView.takeSelectedTabViewItemFromSender)
    }
    
    
    open override func viewWillAppear() {
        
        super.viewWillAppear()
        
        guard self.segmentedControl.segmentCount == 0 else { return }
        
        self.segmentedControl.segmentCount = self.tabViewItems.count - 1
        for (segment, item) in self.tabViewItems.enumerated() {
            self.segmentedControl.setImage(item.image, forSegment: segment)
            self.segmentedControl.setToolTip(item.label, forSegment: segment)
        }
        self.segmentedControl.selectedSegment = self.selectedTabViewItemIndex
    }
    
    
    open override var selectedTabViewItemIndex: Int {
        
        didSet {
            self.segmentedControl.selectedSegment = selectedTabViewItemIndex
        }
    }
    
    
    // MARK: Public Methods
    
    /// Creates an accessory view controller for switching panes.
    ///
    /// - Returns: An accessory view controller that displays the pane selection control.
    public func makeAccessoryViewController() -> NSSplitViewItemAccessoryViewController {
        
        let view = self.segmentedControl
        let containerView = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: containerView.topAnchor),
            view.leadingAnchor.constraint(equalToSystemSpacingAfter: containerView.leadingAnchor, multiplier: 0.5),
            view.trailingAnchor.constraint(equalToSystemSpacingAfter: containerView.trailingAnchor, multiplier: -0.5),
            view.bottomAnchor.constraint(equalToSystemSpacingBelow: containerView.bottomAnchor, multiplier: -0.5),
        ])
        
        // present the pane selector inside the tab view controller's accessibility group
        containerView.setAccessibilityChildren([])
        view.setAccessibilityParent(self.view)
        self.view.setAccessibilityChildren((view.accessibilityChildren() ?? []) + [self.tabView])
        
        let viewController = NSSplitViewItemAccessoryViewController()
        viewController.view = containerView
        viewController.automaticallyAppliesContentInsets = false
        if #available(macOS 26.1, *) {
            viewController.preferredScrollEdgeEffectStyle = .soft
        }
        
        return viewController
    }
}