import Foundation
import Testing
@testable import MinuteMindApp

struct TodoExtractionServiceTests {
    @Test func parsePriorityValues() async throws {
        // Test that TaskPriority enum works correctly
        #expect(TaskPriority.low.displayName == "Low")
        #expect(TaskPriority.medium.displayName == "Medium")
        #expect(TaskPriority.high.displayName == "High")
        #expect(TaskPriority.critical.displayName == "Critical")
        
        // Test rawValue parsing
        #expect(TaskPriority(rawValue: "low") == .low)
        #expect(TaskPriority(rawValue: "high") == .high)
        #expect(TaskPriority(rawValue: "invalid") == nil)
    }
    
    @Test func projectTaskWithNewFields() async throws {
        let projectID = UUID()
        let dueDate = Date()
        
        let task = ProjectTask(
            projectID: projectID,
            title: "Test Task",
            notes: "Some notes",
            assignee: "John Doe",
            dueDate: dueDate,
            priority: .high
        )
        
        #expect(task.title == "Test Task")
        #expect(task.assignee == "John Doe")
        #expect(task.dueDate == dueDate)
        #expect(task.priority == .high)
        #expect(task.isCompleted == false)
    }
    
    @Test func extractedTodoConversion() async throws {
        let projectID = UUID()
        let sessionID = UUID()
        
        let extractedTodos: [TodoExtractionService.ExtractedTodo] = [
            TodoExtractionService.ExtractedTodo(
                title: "Follow up with client",
                assignee: "Sarah",
                dueDate: "2025-01-15",
                priority: "high",
                notes: "Regarding the proposal"
            ),
            TodoExtractionService.ExtractedTodo(
                title: "Review documentation",
                assignee: nil,
                dueDate: nil,
                priority: "low",
                notes: nil
            )
        ]
        
        let tasks = TodoExtractionService.convertToTasks(
            extractedTodos,
            projectID: projectID,
            sourceSessionID: sessionID
        )
        
        #expect(tasks.count == 2)
        
        let firstTask = tasks[0]
        #expect(firstTask.title == "Follow up with client")
        #expect(firstTask.assignee == "Sarah")
        #expect(firstTask.priority == .high)
        #expect(firstTask.notes == "Regarding the proposal")
        #expect(firstTask.projectID == projectID)
        #expect(firstTask.sourceSessionID == sessionID)
        #expect(firstTask.dueDate != nil) // Should parse the date
        
        let secondTask = tasks[1]
        #expect(secondTask.title == "Review documentation")
        #expect(secondTask.assignee == nil)
        #expect(secondTask.priority == .low)
        #expect(secondTask.notes == "")
        // No dueDate in extracted todo — convertToTasks defaults to end of current week (Friday 16:00)
        #expect(secondTask.dueDate != nil)
    }
    
    @Test func extractionResponseParsing() async throws {
        let jsonString = """
        {
            "todos": [
                {
                    "title": "Send report to management",
                    "assignee": "Mike",
                    "dueDate": "next Friday",
                    "priority": "medium",
                    "notes": "Include Q4 numbers"
                }
            ]
        }
        """
        
        let jsonData = jsonString.data(using: .utf8)!
        let response = try JSONDecoder().decode(
            TodoExtractionService.ExtractionResponse.self,
            from: jsonData
        )
        
        #expect(response.todos.count == 1)
        #expect(response.todos[0].title == "Send report to management")
        #expect(response.todos[0].assignee == "Mike")
        #expect(response.todos[0].priority == "medium")
    }
    
    @Test func extractionResponseWithNulls() async throws {
        let jsonString = """
        {
            "todos": [
                {
                    "title": "Basic task",
                    "assignee": null,
                    "dueDate": null,
                    "priority": null,
                    "notes": null
                }
            ]
        }
        """
        
        let jsonData = jsonString.data(using: .utf8)!
        let response = try JSONDecoder().decode(
            TodoExtractionService.ExtractionResponse.self,
            from: jsonData
        )
        
        #expect(response.todos.count == 1)
        #expect(response.todos[0].title == "Basic task")
        #expect(response.todos[0].assignee == nil)
        #expect(response.todos[0].dueDate == nil)
        #expect(response.todos[0].priority == nil)
        #expect(response.todos[0].notes == nil)
    }
    
    @Test func emptyTodosArray() async throws {
        let jsonString = """
        {
            "todos": []
        }
        """
        
        let jsonData = jsonString.data(using: .utf8)!
        let response = try JSONDecoder().decode(
            TodoExtractionService.ExtractionResponse.self,
            from: jsonData
        )
        
        #expect(response.todos.isEmpty)
    }
}
