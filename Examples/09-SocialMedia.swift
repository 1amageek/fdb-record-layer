// Example 09: Social Media Platform
// This example demonstrates a social media platform with users, posts,
// and follow relationships.

import Foundation
import FoundationDB
import FDBRecordCore
import FDBRecordLayer

// MARK: - Model Definitions

@Recordable
struct SocialUser {
    #PrimaryKey<SocialUser>([\.userID])
    #Index<SocialUser>([\.username], name: "user_by_username")

    var userID: Int64
    var username: String
    var displayName: String
    var bio: String
    var followerCount: Int
    var followingCount: Int
}

@Recordable
struct Post {
    #PrimaryKey<Post>([\.postID])
    #Index<Post>([\.authorID, \.createdAt], name: "post_by_author_date")
    #Index<Post>([\.hashtags], name: "post_by_hashtag")

    var postID: Int64
    var authorID: Int64
    var content: String
    var hashtags: [String]
    var likeCount: Int
    var createdAt: Date
}

@Recordable
struct Follow {
    #PrimaryKey<Follow>([\.followerID, \.followeeID])
    #Index<Follow>([\.followerID], name: "follow_by_follower")
    #Index<Follow>([\.followeeID], name: "follow_by_followee")

    var followerID: Int64
    var followeeID: Int64
    var createdAt: Date
}

// MARK: - Example Usage

@main
struct SocialMediaExample {
    static func main() async throws {
        // Initialize
        try FDBNetwork.shared.initialize(version: 710)
        let database = try FDBClient.openDatabase(clusterFilePath: nil)

        // User store
        let userSchema = Schema([SocialUser.self])
        let userSubspace = Subspace(prefix: Tuple("examples", "social", "users").pack())
        let userStore = RecordStore<SocialUser>(
            database: database,
            subspace: userSubspace,
            schema: userSchema,
            statisticsManager: NullStatisticsManager()
        )

        // Post store
        let postSchema = Schema([Post.self])
        let postSubspace = Subspace(prefix: Tuple("examples", "social", "posts").pack())
        let postStore = RecordStore<Post>(
            database: database,
            subspace: postSubspace,
            schema: postSchema,
            statisticsManager: NullStatisticsManager()
        )

        // Follow store
        let followSchema = Schema([Follow.self])
        let followSubspace = Subspace(prefix: Tuple("examples", "social", "follows").pack())
        let followStore = RecordStore<Follow>(
            database: database,
            subspace: followSubspace,
            schema: followSchema,
            statisticsManager: NullStatisticsManager()
        )

        print("📱 Social media platform initialized")

        // MARK: - Create Users

        print("\n👤 Creating users...")
        let users = [
            SocialUser(userID: 1, username: "alice", displayName: "Alice", bio: "Tech enthusiast", followerCount: 0, followingCount: 0),
            SocialUser(userID: 2, username: "bob", displayName: "Bob", bio: "Developer", followerCount: 0, followingCount: 0),
            SocialUser(userID: 3, username: "charlie", displayName: "Charlie", bio: "Designer", followerCount: 0, followingCount: 0),
        ]

        for user in users {
            try await userStore.save(user)
        }
        print("✅ Created \(users.count) users")

        // MARK: - Create Posts

        print("\n📝 Creating posts...")
        let posts = [
            Post(postID: 1, authorID: 1, content: "Hello world! #technology", hashtags: ["technology"], likeCount: 5, createdAt: Date()),
            Post(postID: 2, authorID: 1, content: "Learning Swift #programming #swift", hashtags: ["programming", "swift"], likeCount: 10, createdAt: Date()),
            Post(postID: 3, authorID: 2, content: "Building apps with FoundationDB #database", hashtags: ["database"], likeCount: 8, createdAt: Date()),
            Post(postID: 4, authorID: 3, content: "Design principles #design", hashtags: ["design"], likeCount: 12, createdAt: Date()),
        ]

        for post in posts {
            try await postStore.save(post)
        }
        print("✅ Created \(posts.count) posts")

        // MARK: - Create Follow Relationships

        print("\n👥 Creating follow relationships...")
        let follows = [
            Follow(followerID: 1, followeeID: 2, createdAt: Date()),  // Alice follows Bob
            Follow(followerID: 1, followeeID: 3, createdAt: Date()),  // Alice follows Charlie
            Follow(followerID: 2, followeeID: 1, createdAt: Date()),  // Bob follows Alice
        ]

        for follow in follows {
            try await followStore.save(follow)
        }
        print("✅ Created \(follows.count) follow relationships")

        // MARK: - User Timeline

        let currentUserID: Int64 = 1

        print("\n📰 Fetching timeline for user \(currentUserID)...")
        let following = try await followStore.query()
            .where(\.followerID, .equals, currentUserID)
            .execute()

        let followingIDs = following.map { $0.followeeID }

        let timelinePosts = try await postStore.query()
            .where(\.authorID, .in, followingIDs)
            .orderBy(\.createdAt, .descending)
            .limit(10)
            .execute()

        for post in timelinePosts {
            print("  - Post #\(post.postID): \(post.content) (❤️ \(post.likeCount))")
        }

        // MARK: - Hashtag Search

        print("\n🔖 Searching posts with #programming...")
        let techPosts = try await postStore.query()
            .where(\.hashtags, .contains, "programming")
            .orderBy(\.likeCount, .descending)
            .execute()

        for post in techPosts {
            print("  - \(post.content) (❤️ \(post.likeCount))")
        }

        print("\n🎉 Social media platform example completed!")
    }
}
